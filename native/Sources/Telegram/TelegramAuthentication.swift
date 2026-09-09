import Foundation
import CoreImage

// Keep only presentation metadata, never the phone number or delivered code.
struct TelegramCodeDelivery {
    let instructions: String
    let nextMethod: String?
    let resendAvailableAt: Date?

    init(_ info: TelegramObject, email: Bool = false, now: Date = Date()) {
        if email {
            instructions = "Enter the code sent to your login email address. Check your spam folder too."
            nextMethod = "email"
            resendAvailableAt = now
        } else {
            switch info.object("type").string("@type") {
            case "authenticationCodeTypeTelegramMessage":
                instructions = "Open Telegram on a device where you are already signed in. Look for the verified Telegram service chat and its login code. This code was sent in Telegram, not by SMS."
            case "authenticationCodeTypeSms":
                instructions = "Telegram sent a code by SMS to the phone number you entered. Check your text messages."
            case "authenticationCodeTypeSmsWord":
                instructions = "Telegram sent a word by SMS. Enter the word from that text message."
            case "authenticationCodeTypeSmsPhrase":
                instructions = "Telegram sent a phrase by SMS. Enter the phrase from that text message."
            case "authenticationCodeTypeCall":
                instructions = "Telegram is calling your phone. Enter the code spoken during the call."
            case "authenticationCodeTypeMissedCall":
                let length = Int(info.object("type").number("length"))
                instructions = (1...20).contains(length)
                    ? "Telegram is placing a missed call. Enter the last \(length) digits of the caller’s phone number."
                    : "Telegram is placing a missed call. Enter the requested final digits of the caller’s phone number."
            case "authenticationCodeTypeFlashCall":
                instructions = "Telegram selected automatic call verification. Use QR login or continue in the official mobile app."
            case "authenticationCodeTypeFragment":
                instructions = "Telegram sent the code to Fragment for your collectible phone number. Check Fragment, or use QR login."
            case "authenticationCodeTypeFirebaseAndroid", "authenticationCodeTypeFirebaseIos":
                instructions = "Telegram requires verification through its official mobile app for this method. Use QR login with an already signed-in device."
            default:
                instructions = "Telegram is waiting for a verification code but did not identify a supported delivery method. You can use QR login instead."
            }
            let next = info.object("next_type").string("@type")
            nextMethod = next.isEmpty ? nil : Self.methodName(next)
            resendAvailableAt = next.isEmpty ? nil : now.addingTimeInterval(TimeInterval(max(0, info.number("timeout"))))
        }
    }

    func remaining(at now: Date) -> Int? {
        resendAvailableAt.map { Int(ceil(max(0, $0.timeIntervalSince(now)))) }
    }
    private static func methodName(_ type: String) -> String {
        switch type {
        case "authenticationCodeTypeTelegramMessage": return "Telegram"
        case "authenticationCodeTypeSms", "authenticationCodeTypeSmsWord", "authenticationCodeTypeSmsPhrase": return "SMS"
        case "authenticationCodeTypeCall", "authenticationCodeTypeMissedCall", "authenticationCodeTypeFlashCall": return "phone call"
        default: return "the next available method"
        }
    }
}

enum TelegramLoginQR {
    private static let context = CIContext()

    static func isValid(_ link: String) -> Bool {
        guard link.utf8.count <= 2048, let url = URLComponents(string: link),
              url.scheme == "tg", url.host == "login", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = url.queryItems, query.count == 1, query[0].name == "token",
              let token = query[0].value else { return false }
        return token.range(of: "^[A-Za-z0-9_-]{16,}={0,2}$", options: .regularExpression) != nil
    }

    // The short-lived login token stays in memory. No web QR service, temporary
    // image, clipboard entry, accessibility value, or log receives this link.
    static func image(for link: String) -> CGImage? {
        guard isValid(link), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let bounds = code.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        let padded = code.composited(over: white).cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scale = max(1, floor(256 / padded.extent.width))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
