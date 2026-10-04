//
//  IPAHubPipeline.swift
//  IPA Hub (based on Feather)
//
//  Download → import → sign on device → package into a signed .ipa.
//  Reuses Feather's AppFileHandler, SigningHandler (zsign) and ArchiveHandler.
//

import Foundation
import CoreData
import IDeviceSwift

enum IPAHubStage: Equatable {
	case resolving
	case downloading(Double?)
	case importing
	case signing
	case packaging

	var title: String {
		switch self {
		case .resolving: return "Ищу IPA…"
		case .downloading(let progress):
			if let progress { return "Скачиваю IPA… \(Int(progress * 100))%" }
			return "Скачиваю IPA…"
		case .importing: return "Распаковываю IPA…"
		case .signing: return "Подписываю на iPhone…"
		case .packaging: return "Собираю подписанный IPA…"
		}
	}
}

struct IPAHubResult {
	var signedIPA: URL
	var appName: String
	var version: String?
	var tag: String?
}

enum IPAHubPipeline {
	/// Runs the whole flow for `source` with `certificate`.
	/// `onStage` is always called on the main actor.
	static func run(
		source: IPAHubSource,
		certificate: CertificatePair,
		onStage: @escaping @MainActor (IPAHubStage) -> Void
	) async throws -> IPAHubResult {
		await onStage(.resolving)
		let resolved = try await IPAHubResolver.resolve(source)

		await onStage(.downloading(nil))
		let ipa = try await IPAHubDownloader.download(resolved.url, fileName: resolved.fileName) { progress in
			Task { @MainActor in onStage(.downloading(progress)) }
		}
		defer { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }

		await onStage(.importing)
		let imported = try await importIPA(ipa)

		await onStage(.signing)
		let signed: Signed
		do {
			signed = try await sign(imported, with: certificate)
		} catch {
			await MainActor.run { Storage.shared.deleteApp(for: imported) }
			throw error
		}
		// The unsigned copy is not needed any more; the signed app stays in Library.
		await MainActor.run { Storage.shared.deleteApp(for: imported) }

		await onStage(.packaging)
		let output = try await package(signed, source: source)

		return IPAHubResult(
			signedIPA: output,
			appName: signed.name ?? source.name,
			version: signed.version,
			tag: resolved.tag
		)
	}

	// MARK: Import

	private static func importIPA(_ ipa: URL) async throws -> Imported {
		let handler = AppFileHandler(file: ipa)
		do {
			try await handler.copy()
			try await handler.extract()
			try await handler.move()
			try await handler.addToDatabase()
			try? await handler.clean()
		} catch {
			try? await handler.clean()
			throw error
		}

		let uuid = handler.uuid
		let app: Imported? = await MainActor.run {
			let request: NSFetchRequest<Imported> = Imported.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			return try? Storage.shared.context.fetch(request).first
		}
		guard let app else {
			try? FileManager.default.removeItem(at: FileManager.default.unsigned(uuid))
			throw IPAHubError.importFailed
		}
		return app
	}

	// MARK: Sign

	private static func sign(_ app: Imported, with certificate: CertificatePair) async throws -> Signed {
		// Use the user's Feather signing options, but always sign with the
		// selected certificate (never "only modify").
		var options = await MainActor.run { OptionsManager.shared.options }
		options.signingOption = .default

		let handler = SigningHandler(app: app, options: options)
		handler.appCertificate = certificate

		var signingError: Error?
		do {
			try await handler.copy()
			try await handler.modify()
		} catch {
			signingError = error
		}
		try? await handler.clean()

		let uuid = handler.uuid
		let signed: Signed? = await MainActor.run {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			return try? Storage.shared.context.fetch(request).first
		}

		if let signingError {
			// SigningHandler records the app before reporting a zsign failure;
			// don't leave a broken copy in Library.
			if let signed { await MainActor.run { Storage.shared.deleteApp(for: signed) } }
			if case SigningFileHandlerError.signFailed = signingError { throw IPAHubError.signFailed }
			throw signingError
		}
		guard let signed else { throw IPAHubError.signFailed }
		return signed
	}

	// MARK: Package

	private static func package(_ signed: Signed, source: IPAHubSource) async throws -> URL {
		let viewModel = await MainActor.run { InstallerStatusViewModel(isIdevice: false) }
		let handler = ArchiveHandler(app: signed, viewModel: viewModel)
		try await handler.move()
		let archive = try await handler.archive()
		defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

		let fileManager = FileManager.default
		let folder = fileManager.archives.appendingPathComponent("IPA Hub", isDirectory: true)
		try fileManager.createDirectoryIfNeeded(at: folder)

		let base = [signed.name ?? source.name, signed.version]
			.compactMap { $0 }
			.joined(separator: "_")
		let destination = folder.appendingPathComponent("\(sanitize(base))_signed.ipa")

		try? fileManager.removeItem(at: destination)
		try fileManager.moveItem(at: archive, to: destination)
		return destination
	}

	private static func sanitize(_ name: String) -> String {
		let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
		let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
		return cleaned.isEmpty ? "App" : cleaned
	}
}
