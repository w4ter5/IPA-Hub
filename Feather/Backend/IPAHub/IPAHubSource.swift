//
//  IPAHubSource.swift
//  IPA Hub (based on Feather)
//
//  Personal IPA sources: a public GitHub repository (the IPA is taken from
//  its latest published Release) or a direct HTTPS link to an IPA file.
//  Sources are stored only on this device.
//

import Foundation

struct IPAHubSource: Codable, Identifiable, Equatable, Hashable {
	enum Kind: String, Codable {
		case github
		case direct
	}

	var id = UUID()
	var name: String
	/// Normalized address: `https://github.com/owner/repo` or a direct `https://` link.
	var address: String
	var kind: Kind

	static let shadow = IPAHubSource(
		name: "Shadow",
		address: "https://github.com/folzy1092/Shadow",
		kind: .github
	)

	/// `owner/repo` for GitHub sources.
	var repository: (owner: String, repo: String)? {
		guard kind == .github, let parsed = Self.parseGitHubRepository(address) else { return nil }
		return (owner: parsed.0, repo: parsed.1)
	}

	/// Builds a source from user input. Accepts `owner/repo`,
	/// `github.com/owner/repo`, `https://github.com/owner/repo(.git)(/...)`
	/// and any direct `https://` link (including GitHub release asset links).
	static func make(name: String, input: String) throws -> IPAHubSource {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw IPAHubError.invalidAddress }

		if let parsed = parseGitHubRepository(trimmed) {
			let (owner, repo) = parsed
			let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
			return IPAHubSource(
				name: cleanName.isEmpty ? repo : cleanName,
				address: "https://github.com/\(owner)/\(repo)",
				kind: .github
			)
		}

		guard
			let url = URL(string: trimmed),
			url.scheme?.lowercased() == "https",
			let host = url.host, !host.isEmpty
		else {
			throw IPAHubError.invalidAddress
		}

		let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let fallbackName = url.lastPathComponent.lowercased().hasSuffix(".ipa")
			? String(url.lastPathComponent.dropLast(4))
			: host
		return IPAHubSource(
			name: cleanName.isEmpty ? fallbackName : cleanName,
			address: url.absoluteString,
			kind: .direct
		)
	}

	/// Returns `(owner, repo)` when `input` points at a GitHub repository page
	/// (not at a downloadable release asset).
	static func parseGitHubRepository(_ input: String) -> (String, String)? {
		var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

		if !text.contains("://") {
			let lower = text.lowercased()
			if lower.hasPrefix("github.com/") || lower.hasPrefix("www.github.com/") {
				text = "https://" + text
			} else {
				// `owner/repo` shorthand
				let parts = text.split(separator: "/", omittingEmptySubsequences: true)
				guard parts.count == 2, !text.contains(" "), !text.contains(".ipa") else { return nil }
				text = "https://github.com/" + text
			}
		}

		guard
			let url = URL(string: text),
			url.scheme?.lowercased() == "https",
			let host = url.host?.lowercased(),
			host == "github.com" || host == "www.github.com"
		else {
			return nil
		}

		let parts = url.pathComponents.filter { $0 != "/" }
		guard parts.count >= 2 else { return nil }
		// Direct release asset links are handled as direct downloads.
		if parts.count >= 3, parts[2] == "releases", parts.contains("download") { return nil }

		let owner = parts[0]
		var repo = parts[1]
		if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) }

		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
		guard
			!owner.isEmpty, !repo.isEmpty,
			owner != ".", owner != "..", repo != ".", repo != "..",
			owner.unicodeScalars.allSatisfy(allowed.contains),
			repo.unicodeScalars.allSatisfy(allowed.contains)
		else {
			return nil
		}
		return (owner, repo)
	}
}

/// An IPA file found for a source.
struct IPAHubResolvedIPA: Equatable {
	var url: URL
	var fileName: String
	/// Release tag for GitHub sources, `nil` for direct links.
	var tag: String?
}

enum IPAHubError: LocalizedError, Equatable {
	case invalidAddress
	case duplicateSource
	case repositoryNotFound
	case noRelease
	case noIPAInRelease(String)
	case rateLimited
	case httpStatus(Int)
	case notAnIPA
	case noCertificate
	case importFailed
	case signFailed

	var errorDescription: String? {
		switch self {
		case .invalidAddress:
			return "Введите адрес GitHub-репозитория (https://github.com/владелец/репозиторий или владелец/репозиторий) или прямую HTTPS-ссылку на IPA."
		case .duplicateSource:
			return "Такой источник уже добавлен."
		case .repositoryNotFound:
			return "Репозиторий не найден или он приватный. Поддерживаются только публичные репозитории."
		case .noRelease:
			return "В репозитории нет опубликованных GitHub Releases."
		case .noIPAInRelease(let tag):
			return "В последнем релизе (\(tag)) нет файла .ipa."
		case .rateLimited:
			return "GitHub временно ограничил число запросов без авторизации. Попробуйте позже."
		case .httpStatus(let code):
			return "Сервер ответил кодом \(code)."
		case .notAnIPA:
			return "По ссылке скачался не IPA-файл. Проверьте адрес и доступ к файлу."
		case .noCertificate:
			return "Сначала добавьте сертификат (.p12) и профиль (.mobileprovision)."
		case .importFailed:
			return "Не удалось распаковать IPA: в архиве нет папки Payload с приложением."
		case .signFailed:
			return "Не удалось подписать приложение. Проверьте, что .p12, пароль и .mobileprovision подходят друг к другу и профиль не истёк."
		}
	}
}

enum IPAHubResolver {
	/// Finds the IPA to download for `source`.
	static func resolve(
		_ source: IPAHubSource,
		session: URLSession = .shared
	) async throws -> IPAHubResolvedIPA {
		switch source.kind {
		case .direct:
			guard let url = URL(string: source.address), url.scheme?.lowercased() == "https" else {
				throw IPAHubError.invalidAddress
			}
			let name = url.lastPathComponent.lowercased().hasSuffix(".ipa") ? url.lastPathComponent : "\(source.name).ipa"
			return IPAHubResolvedIPA(url: url, fileName: name, tag: nil)
		case .github:
			guard let repository = source.repository else { throw IPAHubError.invalidAddress }
			return try await latestReleaseIPA(owner: repository.owner, repo: repository.repo, session: session)
		}
	}

	/// Latest published (non-draft, non-prerelease) release of a public repository.
	static func latestReleaseIPA(
		owner: String,
		repo: String,
		session: URLSession = .shared
	) async throws -> IPAHubResolvedIPA {
		let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
		var request = URLRequest(url: api)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		request.setValue("IPA-Hub", forHTTPHeaderField: "User-Agent")
		request.cachePolicy = .reloadIgnoringLocalCacheData

		let (data, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0

		switch status {
		case 200:
			break
		case 404:
			// Either no repo or no published release; tell them apart.
			let exists = try await repositoryExists(owner: owner, repo: repo, session: session)
			throw exists ? IPAHubError.noRelease : IPAHubError.repositoryNotFound
		case 403, 429:
			throw IPAHubError.rateLimited
		default:
			throw IPAHubError.httpStatus(status)
		}

		return try parseRelease(data)
	}

	static func parseRelease(_ data: Data) throws -> IPAHubResolvedIPA {
		struct Release: Decodable {
			struct Asset: Decodable {
				let name: String
				let browser_download_url: String
			}
			let tag_name: String
			let assets: [Asset]
		}

		let release = try JSONDecoder().decode(Release.self, from: data)
		let ipas = release.assets.filter { $0.name.lowercased().hasSuffix(".ipa") }
		guard
			let asset = ipas.first,
			let url = URL(string: asset.browser_download_url),
			url.scheme?.lowercased() == "https"
		else {
			throw IPAHubError.noIPAInRelease(release.tag_name)
		}
		return IPAHubResolvedIPA(url: url, fileName: asset.name, tag: release.tag_name)
	}

	private static func repositoryExists(owner: String, repo: String, session: URLSession) async throws -> Bool {
		var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("IPA-Hub", forHTTPHeaderField: "User-Agent")
		let (_, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		if status == 403 || status == 429 { throw IPAHubError.rateLimited }
		return status == 200
	}
}
