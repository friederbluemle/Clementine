#include "macdevicelister.h"

#include <CoreFoundation/CFRunLoop.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/kext/KextManager.h>
#include <IOKit/IOCFPlugin.h>
#include <IOKit/usb/IOUSBLib.h>

#import <AppKit/NSWorkspace.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

#include <boost/scope_exit.hpp>

#include <libmtp.h>

#include <QtDebug>

#include <QString>
#include <QStringList>

#ifndef kUSBSerialNumberString
#define kUSBSerialNumberString "USB Serial Number"
#endif

#ifndef kUSBVendorString
#define kUSBVendorString "USB Vendor Name"
#endif

#ifndef kUSBProductString
#define kUSBProductString "USB Product Name"
#endif

// Helpful MTP & USB links:
// Apple USB device interface guide:
// http://developer.apple.com/mac/library/documentation/DeviceDrivers/Conceptual/USBBook/USBDeviceInterfaces/USBDevInterfaces.html
// Example Apple code for requesting a USB device descriptor:
// http://www.opensource.apple.com/source/IOUSBFamily/IOUSBFamily-208.4.5/USBProber/BusProbeClass.m
// Libmtp's detection code:
// http://libmtp.cvs.sourceforge.net/viewvc/libmtp/libmtp/src/libusb-glue.c?view=markup
// Libusb's Mac code:
// http://www.libusb.org/browser/libusb/libusb/os/darwin_usb.c
// Microsoft OS Descriptors:
// http://www.microsoft.com/whdc/connect/usb/os_desc.mspx
// Symbian docs for implementing the device side:
// http://developer.symbian.org/main/documentation/reference/s3/pdk/GUID-3FF0F248-EDF0-5348-BC43-869CE1B5B415.html
// Libgphoto2 MTP detection code:
// http://www.sfr-fresh.com/unix/privat/libgphoto2-2.4.10.1.tar.gz:a/libgphoto2-2.4.10.1/libgphoto2_port/usb/check-mtp-device.c

QSet<MacDeviceLister::MTPDevice> MacDeviceLister::sMTPDeviceList;

uint qHash(const MacDeviceLister::MTPDevice& d) {
  return qHash(d.vendor) ^ qHash(d.vendor_id) ^ qHash(d.product) ^ qHash(d.product_id);
}

MacDeviceLister::MacDeviceLister() {
}

MacDeviceLister::~MacDeviceLister() {
  CFRelease(loop_session_);
}

void MacDeviceLister::Init() {
  [[NSAutoreleasePool alloc] init];

  // Populate MTP Device list.
  if (sMTPDeviceList.empty()) {
    LIBMTP_device_entry_t* devices = NULL;
    int num = 0;
    if (LIBMTP_Get_Supported_Devices_List(&devices, &num) != 0) {
      qWarning() << "Failed to get MTP device list";
    } else {
      for (int i = 0; i < num; ++i) {
        LIBMTP_device_entry_t device = devices[i];
        MTPDevice d;
        d.vendor = QString::fromAscii(device.vendor);
        d.vendor_id = device.vendor_id;
        d.product = QString::fromAscii(device.product);
        d.product_id = device.product_id;
      }
    }
  }

  run_loop_ = CFRunLoopGetCurrent();

  // Register for disk mounts/unmounts.
  loop_session_ = DASessionCreate(kCFAllocatorDefault);
  DARegisterDiskAppearedCallback(
      loop_session_, kDADiskDescriptionMatchVolumeMountable, &DiskAddedCallback, reinterpret_cast<void*>(this));
  DARegisterDiskDisappearedCallback(
      loop_session_, NULL, &DiskRemovedCallback, reinterpret_cast<void*>(this));
  DASessionScheduleWithRunLoop(loop_session_, run_loop_, kCFRunLoopDefaultMode);

  // Register for USB device connection/disconnection.
  IONotificationPortRef notification_port = IONotificationPortCreate(kIOMasterPortDefault);
  CFMutableDictionaryRef matching_dict = IOServiceMatching(kIOUSBDeviceClassName);
  io_iterator_t it;
  kern_return_t err = IOServiceAddMatchingNotification(
      notification_port,
      kIOFirstMatchNotification,
      matching_dict,
      &USBDeviceAddedCallback,
      reinterpret_cast<void*>(this),
      &it);
  if (err == KERN_SUCCESS) {
    USBDeviceAddedCallback(this, it);
  } else {
    qWarning() << "Could not add notification on USB device connection";
  }

  CFRunLoopSourceRef io_source = IONotificationPortGetRunLoopSource(notification_port);
  CFRunLoopAddSource(run_loop_, io_source, kCFRunLoopDefaultMode);

  CFRunLoopRun();
}

void MacDeviceLister::ShutDown() {
  CFRunLoopStop(run_loop_);
}


// IOKit helpers.
namespace {

CFTypeRef GetUSBRegistryEntry(io_object_t device, CFStringRef key) {
  io_iterator_t it;
  if (IORegistryEntryGetParentIterator(device, kIOServicePlane, &it) == KERN_SUCCESS) {
    io_object_t next;
    while ((next = IOIteratorNext(it))) {
      CFTypeRef registry_entry = (CFStringRef)IORegistryEntryCreateCFProperty(
          next, key, kCFAllocatorDefault, 0);
      if (registry_entry) {
        IOObjectRelease(next);
        IOObjectRelease(it);
        return registry_entry;
      }

      CFTypeRef ret = GetUSBRegistryEntry(next, key);
      if (ret) {
        IOObjectRelease(next);
        IOObjectRelease(it);
        return ret;
      }

      IOObjectRelease(next);
    }
  }

  IOObjectRelease(it);
  return NULL;
}

QString GetUSBRegistryEntryString(io_object_t device, CFStringRef key) {
  CFStringRef registry_string = (CFStringRef)GetUSBRegistryEntry(device, key);
  if (registry_string) {
    QString ret = QString::fromUtf8([(NSString*)registry_string UTF8String]);
    CFRelease(registry_string);
    return ret;
  }

  return NULL;
}

quint64 GetUSBRegistryEntryInt64(io_object_t device, CFStringRef key) {
  CFNumberRef registry_num = (CFNumberRef)GetUSBRegistryEntry(device, key);
  if (registry_num) {
    qint64 ret = -1;
    Boolean result = CFNumberGetValue(registry_num, kCFNumberLongLongType, &ret);
    if (!result || ret < 0) {
      return 0;
    } else {
      return ret;
    }
  }

  return 0;
}

NSObject* GetPropertyForDevice(io_object_t device, CFStringRef key) {
  CFMutableDictionaryRef properties;
  kern_return_t ret = IORegistryEntryCreateCFProperties(
      device, &properties, kCFAllocatorDefault, 0);

  if (ret != KERN_SUCCESS) {
    return nil;
  }

  NSDictionary* dict = (NSDictionary*)properties;
  NSObject* prop = [dict objectForKey:(NSString*)key];
  if (prop) {
    return prop;
  }

  io_object_t parent;
  ret = IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent);
  if (ret == KERN_SUCCESS) {
    return GetPropertyForDevice(parent, key);
  }

  return nil;
}

QString GetIconForDevice(io_object_t device) {
  NSDictionary* media_icon = (NSDictionary*)GetPropertyForDevice(device, CFSTR("IOMediaIcon"));
  if (media_icon) {
    NSString* bundle = (NSString*)[media_icon objectForKey:@"CFBundleIdentifier"];
    NSString* file = (NSString*)[media_icon objectForKey:@"IOBundleResourceFile"];

    NSURL* bundle_url = (NSURL*)KextManagerCreateURLForBundleIdentifier(
        kCFAllocatorDefault, (CFStringRef)bundle);

    QString path = QString::fromUtf8([[bundle_url path] UTF8String]);
    path += "/Contents/Resources/";
    path += [file UTF8String];
    return path;
  }

  return QString();
}

QString GetSerialForDevice(io_object_t device) {
  return QString(
      "USB/" + GetUSBRegistryEntryString(device, CFSTR(kUSBSerialNumberString)));
}

QString FindDeviceProperty(const QString& bsd_name, CFStringRef property) {
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  io_object_t device = DADiskCopyIOMedia(disk);
  QString ret = GetUSBRegistryEntryString(device, property);
  IOObjectRelease(device);

  CFRelease(disk);
  CFRelease(session);

  return ret;
}

}

void MacDeviceLister::DiskAddedCallback(DADiskRef disk, void* context) {
  MacDeviceLister* me = reinterpret_cast<MacDeviceLister*>(context);

  NSDictionary* properties = (NSDictionary*)DADiskCopyDescription(disk);
  NSURL* volume_path = 
      [[properties objectForKey:(NSString*)kDADiskDescriptionVolumePathKey] copy];

  if (volume_path) {
    io_object_t device = DADiskCopyIOMedia(disk);
    QString vendor = GetUSBRegistryEntryString(device, CFSTR(kUSBVendorString));
    QString product = GetUSBRegistryEntryString(device, CFSTR(kUSBProductString));

    CFMutableDictionaryRef properties;
    kern_return_t ret = IORegistryEntryCreateCFProperties(
        device, &properties, kCFAllocatorDefault, 0);

    if (ret == KERN_SUCCESS) {
      NSDictionary* dict = (NSDictionary*)properties;
      if ([[dict objectForKey:@"Removable"] intValue] == 1) {
        QString serial = GetSerialForDevice(device);
        me->current_devices_[serial] = QString(DADiskGetBSDName(disk));
        emit me->DeviceAdded(serial);
      }
    }

    IOObjectRelease(device);
  }
}

void MacDeviceLister::DiskRemovedCallback(DADiskRef disk, void* context) {
  MacDeviceLister* me = reinterpret_cast<MacDeviceLister*>(context);
  // We cannot access the USB tree when the disk is removed but we still get
  // the BSD disk name.
  for (QMap<QString, QString>::iterator it = me->current_devices_.begin();
       it != me->current_devices_.end(); ++it) {
    if (it.value() == QString::fromLocal8Bit(DADiskGetBSDName(disk))) {
      emit me->DeviceRemoved(it.key());
      me->current_devices_.erase(it);
      break;
    }
  }
}

bool DeviceRequest(IOUSBDeviceInterface** dev,
                   quint8 direction,
                   quint8 type,
                   quint8 recipient,
                   quint8 request_code,
                   quint16 value,
                   quint16 index,
                   quint16 length,
                   QByteArray* data) {
  IOUSBDevRequest req;
  req.bmRequestType = USBmakebmRequestType(direction, type, recipient);
  req.bRequest = request_code;
  req.wValue = value;
  req.wIndex = index;
  req.wLength = length;
  data->resize(256);
  req.pData = data->data();
  kern_return_t err = (*dev)->DeviceRequest(dev, &req);
  if (err != kIOReturnSuccess) {
    return false;
  }
  data->resize(req.wLenDone);
  return true;
}

int GetBusNumber(io_object_t o) {
  io_iterator_t it;
  kern_return_t err = IORegistryEntryGetParentIterator(o, kIOServicePlane, &it);
  if (err != KERN_SUCCESS) {
    return -1;
  }
  while ((o = IOIteratorNext(it))) {
    NSObject* bus = GetPropertyForDevice(o, CFSTR("USBBusNumber"));
    if (bus) {
      NSNumber* bus_num = (NSNumber*)bus;
      return [bus_num intValue];
    }
  }

  return -1;
}

void MacDeviceLister::USBDeviceAddedCallback(void* refcon, io_iterator_t it) {
  MacDeviceLister* me = reinterpret_cast<MacDeviceLister*>(refcon);

  io_object_t object;
  while ((object = IOIteratorNext(it))) {
    CFStringRef class_name = IOObjectCopyClass(object);
    if (CFStringCompare(class_name, CFSTR(kIOUSBDeviceClassName), 0) == kCFCompareEqualTo) {
      NSString* vendor = (NSString*)GetPropertyForDevice(object, CFSTR(kUSBVendorString));
      NSString* product = (NSString*)GetPropertyForDevice(object, CFSTR(kUSBProductString));
      NSNumber* vendor_id = (NSNumber*)GetPropertyForDevice(object, CFSTR(kUSBVendorID));
      NSNumber* product_id = (NSNumber*)GetPropertyForDevice(object, CFSTR(kUSBProductID));

      MTPDevice device;
      device.vendor = QString::fromUtf8([vendor UTF8String]);
      device.product = QString::fromUtf8([product UTF8String]);
      device.vendor_id = [vendor_id unsignedShortValue];
      device.product_id = [product_id unsignedShortValue];

      if (device.vendor_id == 0x5ac) {
        // I think we can safely skip Apple products.
        continue;
      }

      qDebug() << device.vendor
               << device.vendor_id
               << device.product
               << device.product_id;

      NSNumber* addr = (NSNumber*)GetPropertyForDevice(object, CFSTR("USB Address"));
      int bus = GetBusNumber(object);
      qDebug("Bus: %d Address: %d", bus, [addr intValue]);
      if (!addr || bus == -1) {
        // Failed to get bus or address number.
        continue;
      }

      // First check the libmtp device list.
      if (sMTPDeviceList.contains(device)) {
        qDebug() << "Matched device to libmtp list!";
        // emit.
        return;
      }

      IOCFPlugInInterface** plugin_interface = NULL;
      SInt32 score;
      kern_return_t err = IOCreatePlugInInterfaceForService(
          object,
          kIOUSBDeviceUserClientTypeID,
          kIOCFPlugInInterfaceID,
          &plugin_interface,
          &score);
      if (err != KERN_SUCCESS) {
        continue;
      }

      IOUSBDeviceInterface** dev = NULL;
      HRESULT result = (*plugin_interface)->QueryInterface(
          plugin_interface,
          CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
          (LPVOID*)&dev);

      (*plugin_interface)->Release(plugin_interface);

      if (result || !dev) {
        continue;
      }

      err = (*dev)->USBDeviceOpen(dev);
      if (err != kIOReturnSuccess) {
        continue;
      }

      // Automatically close & release usb device at scope exit.
      BOOST_SCOPE_EXIT((dev)) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
      } BOOST_SCOPE_EXIT_END

      // Request the string descriptor at 0xee.
      // This is a magic string that indicates whether this device supports MTP.
      QByteArray data;
      bool ret = DeviceRequest(
          dev, kUSBIn, kUSBStandard, kUSBDevice, kUSBRqGetDescriptor,
          (kUSBStringDesc << 8) | 0xee, 0x0409, 2, &data);
      if (!ret)
        continue;

      UInt8 string_len = data[0];

      ret = DeviceRequest(
          dev, kUSBIn, kUSBStandard, kUSBDevice, kUSBRqGetDescriptor,
          (kUSBStringDesc << 8) | 0xee, 0x0409, string_len, &data);
      if (!ret)
        continue;

      // The device actually returned something. That's a good sign.
      // Because this was designed by MS, the characters are in UTF-16 (LE?).
      QString str = QString::fromUtf16(reinterpret_cast<ushort*>(data.data() + 2), (data.size() / 2) - 2);

      if (str.startsWith("MSFT100")) {
        // We got the OS descriptor!
        char vendor_code = data[16];
        ret = DeviceRequest(
            dev, kUSBIn, kUSBVendor, kUSBDevice, vendor_code, 0, 4, 256, &data);
        if (!ret || data.at(0) != 0x28)
          continue;

        if (QString::fromAscii(data.data() + 0x12, 3) != "MTP") {
          // Not quite.
          continue;
        }

        ret = DeviceRequest(
            dev, kUSBIn, kUSBVendor, kUSBDevice, vendor_code, 0, 5, 256, &data);
        if (!ret || data.at(0) != 0x28) {
          continue;
        }

        if (QString::fromAscii(data.data() + 0x12, 3) != "MTP") {
          // Not quite.
          continue;
        }
        // Hurray! We made it!
        qDebug() << "New MTP device detected!";
      }
    }

    CFRelease(class_name);
    IOObjectRelease(object);
  }
}

QString MacDeviceLister::MakeFriendlyName(const QString& serial) {
  QString bsd_name = current_devices_[serial];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  io_object_t device = DADiskCopyIOMedia(disk);
  QString vendor = GetUSBRegistryEntryString(device, CFSTR(kUSBVendorString));
  QString product = GetUSBRegistryEntryString(device, CFSTR(kUSBProductString));
  IOObjectRelease(device);

  CFRelease(disk);
  CFRelease(session);

  if (vendor.isEmpty()) {
    return product;
  }
  return vendor + " " + product;
}

QList<QUrl> MacDeviceLister::MakeDeviceUrls(const QString& serial) {
  QString bsd_name = current_devices_[serial];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  NSDictionary* properties = (NSDictionary*)DADiskCopyDescription(disk);
  NSURL* volume_path = 
      [[properties objectForKey:(NSString*)kDADiskDescriptionVolumePathKey] copy];

  QString path = [[volume_path path] UTF8String];
  QUrl ret = MakeUrlFromLocalPath(path);

  CFRelease(disk);
  CFRelease(session);

  return QList<QUrl>() << ret;
}

QStringList MacDeviceLister::DeviceUniqueIDs() {
  return current_devices_.keys();
}

QVariantList MacDeviceLister::DeviceIcons(const QString& serial) {
  QString bsd_name = current_devices_[serial];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  io_object_t device = DADiskCopyIOMedia(disk);
  QString icon = GetIconForDevice(device);

  NSDictionary* properties = (NSDictionary*)DADiskCopyDescription(disk);
  NSURL* volume_path = 
      [[properties objectForKey:(NSString*)kDADiskDescriptionVolumePathKey] copy];

  QString path = QString::fromUtf8([[volume_path path] UTF8String]);

  IOObjectRelease(device);
  CFRelease(disk);
  CFRelease(session);

  QVariantList ret;
  ret << GuessIconForPath(path);
  ret << GuessIconForModel(DeviceManufacturer(serial), DeviceModel(serial));
  if (!icon.isEmpty()) {
    ret << icon;
  }
  return ret;
}

QString MacDeviceLister::DeviceManufacturer(const QString& serial){
  return FindDeviceProperty(current_devices_[serial], CFSTR(kUSBVendorString));
}

QString MacDeviceLister::DeviceModel(const QString& serial){
  return FindDeviceProperty(current_devices_[serial], CFSTR(kUSBProductString));
}

quint64 MacDeviceLister::DeviceCapacity(const QString& serial){
  QString bsd_name = current_devices_[serial];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  io_object_t device = DADiskCopyIOMedia(disk);

  NSNumber* capacity = (NSNumber*)GetPropertyForDevice(device, CFSTR("Size"));

  quint64 ret = [capacity unsignedLongLongValue];

  IOObjectRelease(device);

  CFRelease(disk);
  CFRelease(session);

  return ret;
}

quint64 MacDeviceLister::DeviceFreeSpace(const QString& serial){
  QString bsd_name = current_devices_[serial];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, session, bsd_name.toAscii().constData());

  NSDictionary* properties = (NSDictionary*)DADiskCopyDescription(disk);
  NSURL* volume_path =
      [[properties objectForKey:(NSString*)kDADiskDescriptionVolumePathKey] copy];

  FSRef ref;
  OSStatus err = FSPathMakeRef(
      (const UInt8*)[[volume_path path] fileSystemRepresentation], &ref, NULL);
  if (err == noErr) {
    FSCatalogInfo catalog;
    err = FSGetCatalogInfo(&ref, kFSCatInfoVolume, &catalog, NULL, NULL, NULL);
    if (err == noErr) {
      FSVolumeRefNum volume_ref = catalog.volume;
      FSVolumeInfo info;
      err = FSGetVolumeInfo(
          volume_ref, 0, NULL, kFSVolInfoSizes, &info, NULL, NULL);
      UInt64 free_bytes = info.freeBytes;
      return free_bytes;
    }
  }

  return 0;
}

QVariantMap MacDeviceLister::DeviceHardwareInfo(const QString& serial){return QVariantMap();}

void MacDeviceLister::UnmountDevice(const QString& serial) {
  QString bsd_name = current_devices_[serial];
  DADiskRef disk = DADiskCreateFromBSDName(
      kCFAllocatorDefault, loop_session_, bsd_name.toAscii().constData());

  DADiskUnmount(disk, kDADiskUnmountOptionDefault, &DiskUnmountCallback, this);

  CFRelease(disk);
}

void MacDeviceLister::DiskUnmountCallback(
    DADiskRef disk, DADissenterRef dissenter, void* context) {
  if (dissenter) {
    qWarning() << "Another app blocked the unmount";
  } else {
    DiskRemovedCallback(disk, context);
  }
}

void MacDeviceLister::UpdateDeviceFreeSpace(const QString& serial) {
  emit DeviceChanged(serial);
}
