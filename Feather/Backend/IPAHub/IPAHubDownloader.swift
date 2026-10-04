//
//  IPAHubDownloader.swift
//  IPA Hub (based on Feather)
//

import Foundation

// MARK: - Downloader

/// Downloads a file with progress reporting and checks that it is a ZIP (IPA).
final class IPAHubDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	private let _progress: (Double) -> Void
	private let _destination: URL
	private var _continuation: CheckedContinuation<URL, Error>?
	private var _lastReported: Double = -1

	private init(destination: URL, progress: @escaping (Double) -> Void) {
		self._destination = destination
		self._progress = progress
	}

	static func download(
		_ url: URL,
		fileName: String,
		progress: @escaping (Double) -> Void
	) async throws -> URL {
		var name = (fileName as NSString).lastPathComponent
		if !name.lowercased().hasSuffix(".ipa") { name += ".ipa" }
		// AppFileHandler registers the zip extension only for exactly "ipa".
		name = (name as NSString).deletingPathExtension + ".ipa"

		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("IPAHubDownload_\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let destination = folder.appendingPathComponent(name)

		let delegate = IPAHubDownloader(destination: destination, progress: progress)
		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 60 * 60
		let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		defer { session.finishTasksAndInvalidate() }

		var request = URLRequest(url: url)
		request.setValue("IPA-Hub", forHTTPHeaderField: "User-Agent")

		do {
			return try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { continuation in
					delegate._continuation = continuation
					session.downloadTask(with: request).resume()
				}
			} onCancel: {
				session.invalidateAndCancel()
			}
		} catch {
			try? FileManager.default.removeItem(at: folder)
			throw error
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard totalBytesExpectedToWrite > 0 else { return }
		let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
		if value - _lastReported >= 0.01 || value >= 1 {
			_lastReported = value
			_progress(value)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		let result: Result<URL, Error>
		do {
			if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
				throw IPAHubError.httpStatus(http.statusCode)
			}
			let handle = try FileHandle(forReadingFrom: location)
			let header = handle.readData(ofLength: 4)
			try? handle.close()
			// Local file header of a ZIP archive: "PK\u{3}\u{4}".
			guard header == Data([0x50, 0x4B, 0x03, 0x04]) else { throw IPAHubError.notAnIPA }
			try? FileManager.default.removeItem(at: _destination)
			try FileManager.default.moveItem(at: location, to: _destination)
			result = .success(_destination)
		} catch {
			result = .failure(error)
		}
		_finish(result)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error { _finish(.failure(error)) }
	}

	private func _finish(_ result: Result<URL, Error>) {
		guard let continuation = _continuation else { return }
		_continuation = nil
		continuation.resume(with: result)
	}
}
