// Create or edit a bench: name, icon, colour and which projects sit on it.
import SwiftUI
import BurroCore

struct BenchEditor: View {
    @State var bench: Bench
    var benches: BenchesStore
    var projects: [(path: String, name: String)]
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                GradientTile(initial: nil, symbol: bench.symbol, tint: bench.tint, size: 52)
                TextField("Bench name", text: $bench.name, prompt: Text("Work, Homelab, Personal…"))
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ICON").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                    ForEach(Bench.symbols, id: \.self) { symbol in
                        Button { bench.symbol = symbol } label: {
                            Image(systemName: symbol).font(.system(size: 14)).frame(width: 34, height: 34)
                                .background(bench.symbol == symbol ? bench.tint.opacity(0.18) : AppAppearance.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .foregroundStyle(bench.symbol == symbol ? bench.tint : AppAppearance.secondary)
                        }.buttonStyle(.plain).accessibilityLabel(symbol)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("COLOUR").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                HStack(spacing: 10) {
                    ForEach(Bench.colors.indices, id: \.self) { index in
                        Button { bench.color = index } label: {
                            Circle().fill(Bench.colors[index]).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(AppAppearance.text, lineWidth: bench.color == index ? 2 : 0).padding(-3))
                        }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PROJECTS").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
                    Text("\(bench.projects.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                    Spacer()
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(projects.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }, id: \.path) { project in
                            Toggle(isOn: Binding(get: { bench.projects.contains(project.path) }, set: { on in
                                if on { bench.projects.append(project.path) } else { bench.projects.removeAll { $0 == project.path } }
                            })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.name).font(.system(size: 13, weight: .medium))
                                    Text(project.path).font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                            }.toggleStyle(.checkbox).padding(.vertical, 3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200).padding(10)
                .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppAppearance.separator))
            }
            HStack {
                if benches.bench(bench.id) != nil {
                    Button("Delete Bench", role: .destructive) { benches.remove(bench.id); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { benches.save(bench); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(bench.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 520).modifier(AppTheme())
    }
}
