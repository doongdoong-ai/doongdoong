// Compose a README presentation from an unmodified app capture. Run from repo root.
import AppKit
let width = 1400, height = 940
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width*2,pixelsHigh:height*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
bitmap.size = NSSize(width:width,height:height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedRed:0.92,green:0.925,blue:0.905,alpha:1).setFill()
NSBezierPath(rect:NSRect(x:0,y:0,width:width,height:height)).fill()
let frame = NSRect(x:60,y:60,width:1280,height:820)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.12);shadow.shadowBlurRadius=24;shadow.shadowOffset=NSSize(width:0,height:-8);shadow.set()
NSColor.white.setFill();NSBezierPath(roundedRect:frame,xRadius:16,yRadius:16).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect:frame,xRadius:16,yRadius:16).addClip()
NSImage(contentsOfFile:"assets/readme/app-reading.png")!.draw(in:frame,from:.zero,operation:.sourceOver,fraction:1)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"assets/readme/product-overview.png"))
