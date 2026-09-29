import Foundation
import ImageIO

struct PhotoTimestamp {
    let capturedAt: Date?
    let label: String?

    /// Read before sanitization. Never interpret missing EXIF time as the current time.
    static func read(from data: Data) -> PhotoTimestamp {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
              text.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else {
            return PhotoTimestamp(capturedAt: nil, label: nil)
        }
        guard let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
              offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil else {
            return PhotoTimestamp(capturedAt: nil, label: text + "（EXIF 拍摄时间，时区未知）")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        guard let date = formatter.date(from: text + offset), date <= Date().addingTimeInterval(86400) else {
            return PhotoTimestamp(capturedAt: nil, label: text + "（拍摄时间未验证）")
        }
        return PhotoTimestamp(capturedAt: date, label: text + " " + offset + "（EXIF 拍摄时间）")
    }
}
