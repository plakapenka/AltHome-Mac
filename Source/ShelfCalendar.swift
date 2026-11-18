import SwiftUI

struct ShelfCalendar: View {
    private static let locale = Locale(identifier:"ru_RU")
    private var calendar: Calendar {
        var calendar = Calendar(identifier:.gregorian)
        calendar.locale = Self.locale
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar
    }

    let openNotifications: () -> Void
    @State private var selected: Date
    @State private var displayed: Date
    @State private var today: Date
    @State private var hovered: Date?

    init(now: Date = Date(), openNotifications: @escaping () -> Void) {
        self.openNotifications = openNotifications
        _selected = State(initialValue:now)
        _displayed = State(initialValue:now)
        _today = State(initialValue:now)
    }

    private var days: [Date] {
        guard let month = calendar.dateInterval(of:.month, for:displayed) else { return [] }
        let offset = (calendar.component(.weekday,from:month.start) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding:.day, value:$0-offset, to:month.start) }
    }

    private func formatted(_ date: Date, _ format: Date.FormatStyle) -> String {
        date.formatted(format.locale(Self.locale))
    }

    private func choose(_ date: Date) {
        selected = date
        displayed = date
    }

    private func monthButton(_ offset: Int) -> some View {
        let label = offset < 0 ? "Предыдущий месяц" : "Следующий месяц"
        return Button {
            if let start = calendar.dateInterval(of:.month,for:displayed)?.start,
               let next = calendar.date(byAdding:.month,value:offset,to:start) { displayed = next }
        } label: {
            Image(systemName:offset < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size:11,weight:.semibold)).frame(width:26,height:24)
        }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }

    private func dayButton(_ day: Date) -> some View {
        let isToday = calendar.isDate(day,inSameDayAs:today)
        let isSelected = calendar.isDate(day,inSameDayAs:selected)
        let inMonth = calendar.isDate(day,equalTo:displayed,toGranularity:.month)
        return Button { choose(day) } label: {
            Text(String(calendar.component(.day,from:day)))
                .font(.system(size:13,weight:isToday || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.black : Color.primary.opacity(inMonth ? 1 : 0.46))
                .frame(width:30,height:30)
                .background(Circle().fill(isToday ? Self.highlight : Color.primary.opacity(hovered == day ? 0.11 : 0)))
                .overlay(Circle().strokeBorder(Self.highlight.opacity(isSelected && !isToday ? 0.9 : 0),lineWidth:1.5))
                .frame(maxWidth:.infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = day } else if hovered == day { hovered = nil }
        }
        .accessibilityLabel(formatted(day,.dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityValue(isToday ? "Сегодня" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static let highlight = Color(red:0.48,green:0.84,blue:1)
    private let columns = Array(repeating:GridItem(.flexible(),spacing:0),count:7)

    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:2) {
                    Text(formatted(selected,.dateTime.weekday(.wide)).capitalized(with:Self.locale))
                        .font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
                    Text(formatted(selected,.dateTime.day().month(.wide)))
                        .font(.system(size:30,weight:.semibold)).tracking(-0.8)
                }
                Spacer()
                Button { choose(Date()) } label: {
                    Text("Сегодня").font(.system(size:12,weight:.medium))
                        .padding(.horizontal,10).padding(.vertical,5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal,18).padding(.vertical,14)
            .background(LinearGradient(colors:[Self.highlight.opacity(0.14),Self.highlight.opacity(0.02)],
                                       startPoint:.topLeading,endPoint:.bottomTrailing))
            Divider()
            VStack(spacing:8) {
                HStack(spacing:4) {
                    Text(formatted(displayed,.dateTime.month(.wide).year()).capitalized(with:Self.locale))
                        .font(.system(size:14,weight:.semibold))
                    Spacer()
                    monthButton(-1)
                    monthButton(1)
                }.padding(.horizontal,5)
                LazyVGrid(columns:columns,spacing:2) {
                    ForEach(0..<7) { index in
                        let symbol = calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday-1+index)%7]
                        Text(symbol.uppercased(with:Self.locale))
                            .font(.system(size:10,weight:.semibold))
                            .foregroundStyle(.secondary).frame(height:20)
                    }
                    ForEach(days,id:\.self) { dayButton($0) }
                }
            }.padding(.horizontal,13).padding(.vertical,10)
            Divider()
            Button(action:openNotifications) {
                HStack(spacing:9) {
                    Image(systemName:"bell").foregroundStyle(.secondary)
                    Text("Центр уведомлений")
                    Spacer()
                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary)
                }.padding(.horizontal,18).frame(height:39).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size:12,weight:.medium))
        }
        .frame(width:310).fixedSize(horizontal:false,vertical:true)
        .onReceive(NotificationCenter.default.publisher(for:.NSCalendarDayChanged)) { _ in
            let now = Date()
            if calendar.isDate(selected,inSameDayAs:today) && calendar.isDate(displayed,equalTo:today,toGranularity:.month) { choose(now) }
            today = now
        }
    }
}
