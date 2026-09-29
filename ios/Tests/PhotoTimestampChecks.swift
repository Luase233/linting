import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum PhotoTimestampChecks {
    static func image(date: String? = nil, offset: String? = nil) -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var exif: [String: Any] = [:]
        if let date { exif[kCGImagePropertyExifDateTimeOriginal as String] = date }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset }
        CGImageDestinationAddImage(destination, context.makeImage()!,
            [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func main() {
        let timestamp = PhotoTimestamp.read(from: image(date: "2026:09:20 18:30:00", offset: "+08:00"))
        let expected = ISO8601DateFormatter().date(from: "2026-09-20T10:30:00Z")!
        precondition(timestamp.capturedAt == expected, "EXIF timezone offset must define the actual instant")
        let negative = PhotoTimestamp.read(from: image(date: "2026:09:20 02:30:00", offset: "-07:00"))
        precondition(negative.capturedAt == ISO8601DateFormatter().date(from: "2026-09-20T09:30:00Z"),
            "Negative timezone offset")
        let unknownZone = PhotoTimestamp.read(from: image(date: "2026:09:20 18:30:00"))
        precondition(unknownZone.capturedAt == nil && unknownZone.label?.contains("时区未知") == true,
            "Missing timezone cannot become a precise instant")
        let missing = PhotoTimestamp.read(from: image())
        precondition(missing.capturedAt == nil && missing.label == nil, "Missing EXIF must not become today's timestamp")
        let invalidDate = PhotoTimestamp.read(from: image(date: "2026:02:30 18:30:00", offset: "+08:00"))
        precondition(invalidDate.capturedAt == nil, "Impossible date must be rejected")
        let future = PhotoTimestamp.read(from: image(date: "2999:09:20 18:30:00", offset: "+08:00"))
        precondition(future.capturedAt == nil, "Impossible future observation must not become fresh evidence")
        let corrupt = PhotoTimestamp.read(from: Data("not an image".utf8))
        precondition(corrupt.capturedAt == nil && corrupt.label == nil, "Corrupt image")
        print("Photo timestamp checks passed: real JPEG EXIF positive/negative offset, unknown timezone, missing metadata, invalid/future/corrupt input.")
    }
}
