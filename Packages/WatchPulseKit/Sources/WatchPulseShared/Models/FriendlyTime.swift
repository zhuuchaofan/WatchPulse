import Foundation

extension MetricFormatting {
    /// 便于阅读的时刻：“今天 21:19”“昨天 08:05”“10月13日 07:40”，跨年时带年份。
    public static func friendlyDateTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let time = (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
        let dayDelta = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch dayDelta {
        case 0: return "今天 \(time)"
        case 1: return "昨天 \(time)"
        default:
            let sameYear = components.year == calendar.component(.year, from: now)
            let day = "\(components.month ?? 0)月\(components.day ?? 0)日"
            return sameYear ? "\(day) \(time)" : "\(components.year ?? 0)年\(day) \(time)"
        }
    }

    /// 距今多久：“刚刚”“10 分钟前”“3 小时前”“2 天前”。未来时间按“刚刚”处理。
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86_400: return "\(Int(seconds / 3_600)) 小时前"
        default: return "\(Int(seconds / 86_400)) 天前"
        }
    }
}
