//
//  QuickSignView.swift
//  IPA Hub (based on Feather)
//
//  One screen for the whole flow: pick a certificate once, keep a list of
//  sources, tap "Скачать и подписать", then install the signed app on this
//  iPhone (Feather's installer) or save/share the signed IPA.
//  The certificate and its password are stored by Feather's local
//  certificate store on this device and are never uploaded anywhere.
//

import SwiftUI
import CoreData

struct QuickSignView: View {
	@AppStorage("ipaHub.sources") private var _storedSources = ""
	@AppStorage("ipaHub.results") private var _storedResults = ""
	@AppStorage("ipaHub.signedApps") private var _storedSignedApps = ""
	@AppStorage("ipaHub.installAfterSigning") private var _installAfterSigning = true
	@AppStorage("ipaHub.sslRefreshedAt") private var _sslRefreshedAt: Double = 0
	@AppStorage("ipaHub.installServerMigrated") private var _installServerMigrated = false
	@AppStorage("feather.selectedCert") private var _selectedCertificate = 0

	@State private var _sources: [IPAHubSource] = []
	@State private var _results: [UUID: String] = [:]
	/// Source id → UUID of the signed app in Feather's Library.
	@State private var _signedApps: [UUID: String] = [:]
	@State private var _installApp: AnyApp?
	@State private var _isAddingSource = false
	@State private var _isAddingCertificate = false
	@State private var _activeSource: UUID?
	@State private var _stage: IPAHubStage?
	@State private var _lastMessage: String?
	@State private var _errorMessage: String?
	@State private var _task: Task<Void, Never>?

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
	) private var _certificates: FetchedResults<CertificatePair>

	private var _isBusy: Bool { _activeSource != nil }

	private var _certificate: CertificatePair? {
		_certificates.indices.contains(_selectedCertificate) ? _certificates[_selectedCertificate] : nil
	}

	// MARK: Body
	var body: some View {
		NavigationStack {
			List {
				_certificateSection
				_sourcesSection
				Section {
					Toggle("Устанавливать сразу после подписи", isOn: $_installAfterSigning)
				} footer: {
					Text("После подписи iOS спросит, установить ли приложение. Его также можно установить кнопкой «Установить» или из «Библиотеки».")
				}
				if let message = _lastMessage, !_isBusy {
					Section("Состояние") { Text(message) }
				}
			}
			.navigationTitle("IPA Hub")
			.toolbar {
				if _sources.count > 1 { EditButton().disabled(_isBusy) }
			}
			.onAppear(perform: _load)
			.onChange(of: _certificates.count) { _ in
				// A newly imported certificate is the newest one (index 0).
				if !_certificates.indices.contains(_selectedCertificate) || _isAddingCertificate {
					_selectedCertificate = 0
				}
			}
			.sheet(isPresented: $_isAddingCertificate) { CertificatesAddView() }
			.sheet(item: $_installApp) { app in
				InstallPreviewView(app: app.base)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.sheet(isPresented: $_isAddingSource) {
				IPAHubAddSourceView(existing: _sources) { source in
					_sources.append(source)
					_saveSources()
				}
			}
			.alert("Ошибка", isPresented: Binding(
				get: { _errorMessage != nil },
				set: { if !$0 { _errorMessage = nil } }
			)) {
				Button("ОК", role: .cancel) { _errorMessage = nil }
			} message: {
				Text(_errorMessage ?? "")
			}
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var _certificateSection: some View {
		Section {
			if _certificates.isEmpty {
				Button {
					_isAddingCertificate = true
				} label: {
					Label("Добавить .p12 и .mobileprovision", systemImage: "person.badge.key")
				}
			} else {
				Picker("Сертификат", selection: $_selectedCertificate) {
					ForEach(Array(_certificates.enumerated()), id: \.offset) { index, certificate in
						Text(_certificateTitle(certificate, index: index)).tag(index)
					}
				}
				.disabled(_isBusy)
				if let certificate = _certificate, let expiration = certificate.expiration {
					LabeledContent("Действует до") {
						Text(expiration, style: .date)
							.foregroundStyle(expiration < Date() ? .red : .secondary)
					}
				}
				Button("Добавить другой сертификат") { _isAddingCertificate = true }
					.disabled(_isBusy)
			}
		} header: {
			Text("Сертификат")
		} footer: {
			Text("Файлы сертификата и пароль хранятся только в этом приложении на iPhone.")
		}
	}

	@ViewBuilder
	private var _sourcesSection: some View {
		Section {
			if _sources.isEmpty {
				Text("Добавьте GitHub-репозиторий или прямую ссылку на IPA.")
					.foregroundStyle(.secondary)
			}
			ForEach(_sources) { source in
				_sourceRow(source)
			}
			.onDelete { offsets in
				guard !_isBusy else { return }
				for index in offsets {
					_removeResult(for: _sources[index].id)
					_signedApps[_sources[index].id] = nil
				}
				_saveSignedApps()
				_sources.remove(atOffsets: offsets)
				_saveSources()
			}
			.onMove { from, to in
				_sources.move(fromOffsets: from, toOffset: to)
				_saveSources()
			}
			Button {
				_isAddingSource = true
			} label: {
				Label("Добавить источник", systemImage: "plus")
			}
			.disabled(_isBusy)
		} header: {
			Text("Источники IPA")
		} footer: {
			Text("Для GitHub берётся файл .ipa из последнего опубликованного Release (без черновиков и пре-релизов). Поддерживаются только публичные репозитории и ссылки без авторизации.")
		}
	}

	private func _sourceRow(_ source: IPAHubSource) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Image(systemName: source.kind == .github ? "shippingbox" : "link")
					.foregroundStyle(.secondary)
				Text(source.name).font(.headline)
			}
			Text(source.address)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.textSelection(.enabled)

			if _activeSource == source.id, let stage = _stage {
				// One fixed layout for every stage so the row doesn't jump around.
				VStack(alignment: .leading, spacing: 6) {
					Text(stage.title)
						.font(.footnote)
						.monospacedDigit()
						.lineLimit(1)
					ProgressView(value: stage.fraction)
						.animation(.linear(duration: 0.2), value: stage.fraction)
				}
				Button(role: .destructive) {
					_task?.cancel()
				} label: {
					Text("Отменить").frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
			} else {
				Button {
					_start(source)
				} label: {
					Label("Скачать и подписать", systemImage: "signature")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.disabled(_isBusy || _certificate == nil)

				let app = _signedApp(for: source.id)
				let file = _resultFile(for: source.id)
				if app != nil || file != nil {
					HStack(spacing: 10) {
						if let app {
							Button {
								_installApp = AnyApp(base: app)
							} label: {
								Label("Установить", systemImage: "arrow.down.app")
									.lineLimit(1)
									.frame(maxWidth: .infinity)
							}
						}
						if let file {
							ShareLink(item: file) {
								Label("Поделиться", systemImage: "square.and.arrow.up")
									.lineLimit(1)
									.frame(maxWidth: .infinity)
							}
						}
					}
					.buttonStyle(.bordered)
					.controlSize(.large)
					.disabled(_isBusy)
				}
				if let file {
					Text(file.lastPathComponent)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
		}
		.padding(.vertical, 4)
	}


	// MARK: Actions

	private func _start(_ source: IPAHubSource) {
		guard let certificate = _certificate else {
			_errorMessage = IPAHubError.noCertificate.localizedDescription
			return
		}
		_activeSource = source.id
		_stage = .resolving
		_lastMessage = nil

		_task = Task { @MainActor in
			do {
				let result = try await IPAHubPipeline.run(source: source, certificate: certificate) { stage in
					_stage = stage
				}
				_results[source.id] = result.signedIPA.lastPathComponent
				_saveResults()
				_signedApps[source.id] = result.signedUUID
				_saveSignedApps()
				let release = result.tag.map { " (релиз \($0))" } ?? ""
				let version = result.version.map { " \($0)" } ?? ""
				_lastMessage = "Готово: \(result.appName)\(version)\(release) подписан. Нажмите «Установить», чтобы поставить его на iPhone, или «Поделиться», чтобы сохранить файл."
				if _installAfterSigning, let app = _signedApp(for: source.id) {
					_installApp = AnyApp(base: app)
				}
			} catch is CancellationError {
				_lastMessage = "Отменено."
			} catch let error as URLError where error.code == .cancelled {
				_lastMessage = "Отменено."
			} catch {
				_lastMessage = nil
				_errorMessage = error.localizedDescription
			}
			_stage = nil
			_activeSource = nil
			_task = nil
		}
	}

	// MARK: Persistence

	private func _load() {
		_useLoopbackInstallServer()
		_refreshInstallCertificatesIfNeeded()

		if _storedSources.isEmpty {
			_sources = [.shadow]
			_saveSources()
		} else if
			let data = _storedSources.data(using: .utf8),
			let saved = try? JSONDecoder().decode([IPAHubSource].self, from: data)
		{
			_sources = saved
		} else {
			_sources = _migrateLegacySources() ?? [.shadow]
			_saveSources()
		}

		if
			let data = _storedResults.data(using: .utf8),
			let saved = try? JSONDecoder().decode([UUID: String].self, from: data)
		{
			_results = saved
		}

		if
			let data = _storedSignedApps.data(using: .utf8),
			let saved = try? JSONDecoder().decode([UUID: String].self, from: data)
		{
			_signedApps = saved
		}
	}

	/// Sources saved by the first IPA Hub prototype used a different shape.
	private func _migrateLegacySources() -> [IPAHubSource]? {
		struct Legacy: Decodable { var name: String; var address: String }
		guard
			let data = _storedSources.data(using: .utf8),
			let legacy = try? JSONDecoder().decode([Legacy].self, from: data)
		else {
			return nil
		}
		return legacy.compactMap { try? IPAHubSource.make(name: $0.name, input: $0.address) }
	}

	private func _saveSources() {
		guard
			let data = try? JSONEncoder().encode(_sources),
			let string = String(data: data, encoding: .utf8)
		else {
			return
		}
		_storedSources = string
	}

	private func _saveResults() {
		guard
			let data = try? JSONEncoder().encode(_results),
			let string = String(data: data, encoding: .utf8)
		else {
			return
		}
		_storedResults = string
	}

	/// Feather's "Fully Local" install needs local.backloop.dev to resolve to
	/// 127.0.0.1. VPN apps with fake-IP DNS (and some DNS filters) break that,
	/// so the install hangs at "Ready". "Semi Local" + "localhost only" serves
	/// the IPA from http://127.0.0.1 with no DNS lookup; only the small install
	/// manifest comes from api.palera.in (Feather's built-in option).
	/// Done once; the user can switch back in Settings → Installation.
	private func _useLoopbackInstallServer() {
		guard !_installServerMigrated else { return }
		UserDefaults.standard.set(1, forKey: "Feather.serverMethod")
		UserDefaults.standard.set(true, forKey: "Feather.ipFix")
		_installServerMigrated = true
	}

	/// The local install server uses a short-lived backloop.dev certificate
	/// (~90 days) bundled at build time. Refresh it every few days so
	/// "Установить" keeps working without rebuilding IPA Hub.
	private func _refreshInstallCertificatesIfNeeded() {
		let now = Date().timeIntervalSince1970
		guard now - _sslRefreshedAt > 3 * 24 * 60 * 60 else { return }
		FR.downloadSSLCertificates(from: "https://backloop.dev/pack.json") { success in
			guard success else { return }
			DispatchQueue.main.async { _sslRefreshedAt = now }
		}
	}

	private func _saveSignedApps() {
		guard
			let data = try? JSONEncoder().encode(_signedApps),
			let string = String(data: data, encoding: .utf8)
		else {
			return
		}
		_storedSignedApps = string
	}

	/// The signed app from the last run, if it is still in Feather's Library.
	private func _signedApp(for id: UUID) -> Signed? {
		guard let uuid = _signedApps[id] else { return nil }
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1
		return try? Storage.shared.context.fetch(request).first
	}

	private func _resultFile(for id: UUID) -> URL? {
		guard let name = _results[id] else { return nil }
		let url = FileManager.default.archives
			.appendingPathComponent("IPA Hub", isDirectory: true)
			.appendingPathComponent(name)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	private func _removeResult(for id: UUID) {
		_results[id] = nil
		_saveResults()
	}

	private func _certificateTitle(_ certificate: CertificatePair, index: Int) -> String {
		if let nickname = certificate.nickname, !nickname.isEmpty { return nickname }
		if let name = Storage.shared.getProvisionFileDecoded(for: certificate)?.Name { return name }
		return "Сертификат \(index + 1)"
	}
}

// MARK: - Add source

struct IPAHubAddSourceView: View {
	@Environment(\.dismiss) private var dismiss

	let existing: [IPAHubSource]
	let onSave: (IPAHubSource) -> Void

	@State private var _name = ""
	@State private var _address = ""
	@State private var _errorMessage: String?
	@State private var _isChecking = false
	@State private var _checkResult: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("https://github.com/владелец/репозиторий", text: $_address)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.URL)
					TextField("Название (необязательно)", text: $_name)
				} footer: {
					Text("Ссылка на публичный GitHub-репозиторий (IPA берётся из последнего Release) или прямая HTTPS-ссылка на файл .ipa.")
				}

				if _isChecking {
					Section { HStack { ProgressView(); Text("Проверяю…") } }
				} else if let _checkResult {
					Section { Text(_checkResult).font(.footnote) }
				}
				if let _errorMessage {
					Section { Text(_errorMessage).foregroundStyle(.red).font(.footnote) }
				}
			}
			.navigationTitle("Новый источник")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Отмена") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Сохранить") { _save() }
						.disabled(_address.trimmingCharacters(in: .whitespaces).isEmpty || _isChecking)
				}
			}
		}
	}

	private func _save() {
		_errorMessage = nil
		_checkResult = nil
		let source: IPAHubSource
		do {
			source = try IPAHubSource.make(name: _name, input: _address)
		} catch {
			_errorMessage = error.localizedDescription
			return
		}
		guard !existing.contains(where: { $0.address.caseInsensitiveCompare(source.address) == .orderedSame }) else {
			_errorMessage = IPAHubError.duplicateSource.localizedDescription
			return
		}
		guard source.kind == .github else {
			onSave(source)
			dismiss()
			return
		}
		// Check that the repository has a release with an IPA right away,
		// so problems show up now and not on the first download.
		_isChecking = true
		Task { @MainActor in
			defer { _isChecking = false }
			do {
				let resolved = try await IPAHubResolver.resolve(source)
				_checkResult = "Найден \(resolved.fileName) в релизе \(resolved.tag ?? "")."
				onSave(source)
				dismiss()
			} catch let error as IPAHubError where error == .rateLimited {
				// Can't verify right now; keep the source anyway.
				onSave(source)
				dismiss()
			} catch {
				_errorMessage = error.localizedDescription
			}
		}
	}
}
