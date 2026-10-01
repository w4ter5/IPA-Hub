import SwiftUI
import CoreData
import IDeviceSwift

// Personal sources stay on this device. The signing certificate is managed by
// Feather's existing local certificate store; it is never sent to GitHub.
private struct QuickSource: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case github = "GitHub Releases"
        case direct = "Прямая ссылка на IPA"
    }

    var id = UUID()
    var name: String
    var address: String
    var kind: Kind

    func ipaURL(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = URL(string: address), url.scheme == "https" else {
            completion(.failure(QuickSignError.invalidAddress))
            return
        }
        if kind == .direct {
            guard url.path.lowercased().hasSuffix(".ipa") else {
                completion(.failure(QuickSignError.invalidIPA))
                return
            }
            completion(.success(url))
            return
        }
        guard url.host?.lowercased() == "github.com" else {
            completion(.failure(QuickSignError.invalidRepository))
            return
        }
        var parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] != ".", parts[1] != "." else {
            completion(.failure(QuickSignError.invalidRepository))
            return
        }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        let apiURL = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = object["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }),
                  let link = asset["browser_download_url"] as? String,
                  let ipaURL = URL(string: link), ipaURL.scheme == "https" else {
                completion(.failure(QuickSignError.noReleaseIPA))
                return
            }
            completion(.success(ipaURL))
        }.resume()
    }
}

private enum QuickSignError: LocalizedError {
    case invalidAddress, invalidRepository, invalidIPA, noReleaseIPA, badDownload, noCertificate, noImportedApp, noSignedApp

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Введите ссылку HTTPS."
        case .invalidRepository: return "Введите адрес вида https://github.com/владелец/репозиторий."
        case .invalidIPA: return "Прямая ссылка должна вести на файл .ipa."
        case .noReleaseIPA: return "В последнем GitHub Release нет файла IPA или релиз недоступен."
        case .badDownload: return "По ссылке скачался не IPA. Проверьте адрес и доступ к файлу."
        case .noCertificate: return "Сначала добавьте сертификат и профиль."
        case .noImportedApp: return "Не удалось найти импортированное приложение."
        case .noSignedApp: return "Не удалось найти подписанное приложение."
        }
    }
}

struct QuickSignView: View {
    @AppStorage("ipaHub.sources") private var storedSources = ""
    @AppStorage("feather.selectedCert") private var selectedCertificate = 0
    @State private var sources: [QuickSource] = []
    @State private var showingSourceEditor = false
    @State private var showingCertificateImporter = false
    @State private var name = ""
    @State private var address = ""
    @State private var kind: QuickSource.Kind = .github
    @State private var busy = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var signedIPA: URL?

    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var certificates: FetchedResults<CertificatePair>

    var body: some View {
        NavigationStack {
            List {
                Section("Сертификат") {
                    if certificates.isEmpty {
                        Button("Добавить .p12 и .mobileprovision") { showingCertificateImporter = true }
                    } else {
                        Picker("Использовать", selection: $selectedCertificate) {
                            ForEach(Array(certificates.enumerated()), id: \.offset) { index, certificate in
                                Text(certificate.nickname ?? "Сертификат \(index + 1)").tag(index)
                            }
                        }
                        Button("Добавить другой сертификат") { showingCertificateImporter = true }
                    }
                }

                Section("Источники IPA") {
                    if sources.isEmpty {
                        Text("Добавьте GitHub-репозиторий или прямую ссылку на IPA.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.name).font(.headline)
                            Text(source.address).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button("Скачать и подписать") { start(source) }
                                .disabled(busy || certificates.isEmpty)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        sources.remove(atOffsets: offsets)
                        saveSources()
                    }
                    Button("Добавить источник") {
                        name = ""
                        address = ""
                        kind = .github
                        showingSourceEditor = true
                    }
                }

                if busy || !status.isEmpty {
                    Section("Состояние") {
                        if busy { ProgressView() }
                        Text(status)
                    }
                }
                if let signedIPA {
                    Section("Готовый файл") {
                        ShareLink(item: signedIPA) {
                            Label("Сохранить или отправить подписанный IPA", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("IPA Hub")
            .onAppear(perform: loadSources)
            .sheet(isPresented: $showingCertificateImporter) { CertificatesAddView() }
            .sheet(isPresented: $showingSourceEditor) { sourceEditor }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("ОК") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var sourceEditor: some View {
        NavigationStack {
            Form {
                Picker("Тип", selection: $kind) {
                    ForEach(QuickSource.Kind.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                TextField("Название", text: $name)
                TextField(kind == .github ? "https://github.com/owner/repo" : "https://example.com/app.ipa", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .navigationTitle("Новый источник")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showingSourceEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmed), url.scheme == "https",
                              kind != .github || (url.host?.lowercased() == "github.com" && url.pathComponents.count >= 3),
                              kind != .direct || url.path.lowercased().hasSuffix(".ipa") else {
                            errorMessage = QuickSignError.invalidAddress.localizedDescription
                            return
                        }
                        sources.append(QuickSource(name: name.isEmpty ? (url.host ?? "IPA") : name, address: trimmed, kind: kind))
                        saveSources()
                        showingSourceEditor = false
                    }
                }
            }
        }
    }

    private func loadSources() {
        if storedSources.isEmpty {
            sources = [QuickSource(name: "Shadow", address: "https://github.com/folzy1092/Shadow", kind: .github)]
            saveSources()
        } else if let data = storedSources.data(using: .utf8),
                  let saved = try? JSONDecoder().decode([QuickSource].self, from: data) {
            sources = saved
        }
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources),
              let string = String(data: data, encoding: .utf8) else { return }
        storedSources = string
    }

    private func fail(_ error: Error) {
        busy = false
        status = ""
        errorMessage = error.localizedDescription
    }

    private func start(_ source: QuickSource) {
        guard certificates.indices.contains(selectedCertificate) else {
            fail(QuickSignError.noCertificate)
            return
        }
        let certificate = certificates[selectedCertificate]
        busy = true
        status = "Ищу IPA…"
        signedIPA = nil
        source.ipaURL { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): fail(error)
                case .success(let url): download(url, certificate: certificate)
                }
            }
        }
    }

    private func download(_ url: URL, certificate: CertificatePair) {
        status = "Скачиваю IPA…"
        URLSession.shared.downloadTask(with: url) { temporaryURL, _, error in
            if let error { DispatchQueue.main.async { fail(error) }; return }
            guard let temporaryURL else {
                DispatchQueue.main.async { fail(QuickSignError.badDownload) }
                return
            }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
            do {
                let handle = try FileHandle(forReadingFrom: temporaryURL)
                let header = handle.readData(ofLength: 4)
                try handle.close()
                guard header.starts(with: [0x50, 0x4b]) else { throw QuickSignError.badDownload }
                try FileManager.default.copyItem(at: temporaryURL, to: copy)
                DispatchQueue.main.async { importAndSign(copy, certificate: certificate) }
            } catch {
                DispatchQueue.main.async { fail(error) }
            }
        }.resume()
    }

    private func importAndSign(_ ipa: URL, certificate: CertificatePair) {
        status = "Подготавливаю IPA…"
        let started = Date()
        FR.handlePackageFile(ipa) { error in
            try? FileManager.default.removeItem(at: ipa)
            if let error { fail(error); return }
            let request: NSFetchRequest<Imported> = Imported.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
            guard let imported = try? Storage.shared.context.fetch(request).first,
                  (imported.date ?? .distantPast) >= started.addingTimeInterval(-2) else {
                fail(QuickSignError.noImportedApp)
                return
            }
            status = "Подписываю на iPhone…"
            FR.signPackageFile(imported, using: OptionsManager.shared.options, icon: nil, certificate: certificate) { error in
                if let error { fail(error); return }
                packageSignedApp()
            }
        }
    }

    private func packageSignedApp() {
        status = "Собираю подписанный IPA…"
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        guard let signed = try? Storage.shared.context.fetch(request).first else {
            fail(QuickSignError.noSignedApp)
            return
        }
        Task {
            do {
                let handler = ArchiveHandler(app: signed, viewModel: InstallerStatusViewModel())
                try await handler.move()
                let archive = try await handler.archive()
                try FileManager.default.createDirectory(at: FileManager.default.archives, withIntermediateDirectories: true)
                let destination = FileManager.default.archives.appendingPathComponent("Signed-\(UUID().uuidString).ipa")
                try FileManager.default.copyItem(at: archive, to: destination)
                signedIPA = destination
                status = "Готово: IPA подписан и сохранён на этом iPhone."
                busy = false
            } catch {
                fail(error)
            }
        }
    }
}
