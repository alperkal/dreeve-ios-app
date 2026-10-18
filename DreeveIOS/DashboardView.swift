import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var session: DreeveSession

    @EnvironmentObject private var persistence: GoalPersistence

    private var insights: ActivityInsights { ActivityInsights(activities: session.insightsActivities) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR TRAINING")
                                .font(.caption.weight(.semibold))
                                .tracking(2)
                                .foregroundStyle(DreeveTheme.accent)
                            Text("Keep moving.")
                                .font(.system(size: 36, weight: .heavy, design: .rounded))
                        }
                        Spacer()
                        Image(systemName: "figure.run.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(DreeveTheme.accent)
                    }
                    .padding(.top, 12)

                    if session.showsActivityIndexStatus { ActivityIndexStatusView() }
                    if persistence.container != nil {
                        FavoriteGoalsView()
                        CoachGoalsSection()
                    } else { CoachDashboardHost(goals: []) }

                    Text("This week")
                        .font(.title3.weight(.bold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricView(title: "Distance", value: "\(insights.weekKm.oneDecimal) km", symbol: "point.topleft.down.curvedto.point.bottomright.up")
                        MetricView(title: "Moving time", value: "\(Int(insights.weekMinutes)) min", symbol: "clock")
                        MetricView(title: "Activities", value: "\(insights.currentWeek.count)", symbol: "figure.run")
                        MetricView(title: "30-day climb", value: "\(Int(insights.monthElevation)) m", symbol: "mountain.2")
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DISTANCE TREND")
                                        .font(.caption.weight(.semibold))
                                        .tracking(1.5)
                                        .foregroundStyle(DreeveTheme.muted)
                                    Text("Last 7 days")
                                        .font(.headline)
                                }
                                Spacer()
                                Text("\(insights.weekKm.oneDecimal) km")
                                    .foregroundStyle(DreeveTheme.accent)
                                    .font(.headline.monospacedDigit())
                            }
                            Chart {
                                ForEach(insights.dailyDistances) { point in
                                    BarMark(
                                        x: .value("Day", point.day, unit: .day),
                                        y: .value("Distance", point.km)
                                    )
                                    .foregroundStyle(DreeveTheme.accent.gradient)
                                    .cornerRadius(5)
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) {
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel(anchor: .trailing)
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day)) { _ in
                                    AxisValueLabel(format: .dateTime.weekday(.narrow), anchor: .top)
                                }
                            }
                            .frame(height: 150)
                        }
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("SPORTS · LAST 30 DAYS")
                                    .font(.caption.weight(.semibold))
                                    .tracking(1)
                                    .foregroundStyle(DreeveTheme.muted)
                                Spacer()
                                Text("\(insights.monthKm.oneDecimal) km")
                                    .foregroundStyle(DreeveTheme.accent)
                                    .font(.subheadline.bold())
                            }
                            if insights.sports.isEmpty {
                                Text("No activity data for this period.")
                                    .foregroundStyle(DreeveTheme.muted)
                            }
                            ForEach(insights.sports) { item in
                                NavigationLink {
                                    ActivitiesView(embedded: true, sportFilter: ActivitySportFilter(sport: item.id))
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: activitySymbol(item.id))
                                            .foregroundStyle(DreeveTheme.accent)
                                            .frame(width: 24)
                                        Text(item.id)
                                        Spacer()
                                        Text("\(item.count)")
                                            .foregroundStyle(DreeveTheme.muted)
                                            .monospacedDigit()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(DreeveTheme.muted)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.id), \(item.count) activities in the last 30 days")
                            }
                        }
                    }

                    Text("Insights cover the last 30 days, calculated on-device from your Dreeve activities.")
                        .font(.caption)
                        .foregroundStyle(DreeveTheme.muted)
                        .padding(.horizontal, 3)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
            }
            .dreeveBackground()
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await session.refreshInsights(forceFullReconcile: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(session.isLoadingInsights || session.isSyncingActivityIndex)
                }
            }
            .overlay {
                if session.isLoadingInsights && !session.didLoadInsights {
                    ProgressView("Loading insights…")
                }
            }
            .task {
                if !session.didLoadInsights { await session.refreshInsights() }
            }
            .refreshable { await session.refreshInsights(forceFullReconcile: true) }
            .alert("Request failed", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "Unknown error")
            }
        }
    }
}
