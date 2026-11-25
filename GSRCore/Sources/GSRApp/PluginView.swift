import AVFoundation
import AppKit
import CoreAudioKit

/// Gets the graphical interface of an AU plugin:
/// 1. AUv3 view (requestViewController), 2. AUv2 Cocoa view, 3. generic view.
@MainActor
enum PluginView {
    static func make(for unit: AVAudioUnit) async -> NSView {
        let au = unit.auAudioUnit

        let controller: NSViewController? = await withCheckedContinuation { continuation in
            au.requestViewController { continuation.resume(returning: $0) }
        }
        if let view = controller?.view {
            if controller!.preferredContentSize != .zero {
                view.setFrameSize(controller!.preferredContentSize)
            }
            objc_setAssociatedObject(view, &controllerKey, controller, .OBJC_ASSOCIATION_RETAIN)
            return view
        }
        if let view = cocoaView(for: unit.audioUnit) { return view }

        let generic = AUGenericView(audioUnit: unit.audioUnit)
        generic.showsExpertParameters = false
        return generic
    }

    private static var controllerKey = 0

    /// Cocoa view provided by an AUv2 plugin (kAudioUnitProperty_CocoaUI).
    private static func cocoaView(for unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }

        let info = raw.load(as: AudioUnitCocoaViewInfo.self)
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String

        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let factoryClass = bundle.classNamed(className) as? NSObject.Type,
              factoryClass.instancesRespond(to: selector) else { return nil }
        // AUCocoaUIBase isn't exposed in Swift: call -uiViewForAudioUnit:withSize: directly.
        let factory = factoryClass.init()
        typealias Factory = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let imp = unsafeBitCast(factory.method(for: selector), to: Factory.self)
        return imp(factory, selector, unit, NSSize(width: 800, height: 600))?.takeUnretainedValue()
    }
}
