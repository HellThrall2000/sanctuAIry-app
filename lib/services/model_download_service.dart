import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// How one host's turn ended.
enum _Attempt {
  /// The model is on disk and verified.
  done,

  /// Stop entirely — the user paused, or the file failed its checksum. Neither
  /// is something a different host can fix.
  abort,

  /// This host did not work. Try the next mirror, keeping whatever bytes it
  /// managed to deliver.
  retryElsewhere,
}

/// Where the download has got to.
enum DownloadStage {
  /// Nothing has happened yet, or the model is absent and untouched.
  idle,

  /// Waiting for a network the user is willing to spend — see
  /// [ModelDownloadService.wifiOnly].
  waitingForWifi,

  downloading,

  /// Stopped by the user, with a `.part` file on disk to resume from.
  paused,

  /// Hashing the finished file.
  verifying,

  /// The model is on disk and usable.
  ready,

  failed,
}

/// Immutable snapshot of download state, for the UI to render.
@immutable
class DownloadStatus {
  final DownloadStage stage;
  final int receivedBytes;
  final int totalBytes;

  /// Bytes per second over the recent window, or null before there is enough
  /// to estimate from.
  final double? bytesPerSecond;

  /// Plain-language failure, ready to show. Null unless [stage] is
  /// [DownloadStage.failed].
  final String? error;

  const DownloadStatus({
    required this.stage,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond,
    this.error,
  });

  double get fraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isActive =>
      stage == DownloadStage.downloading || stage == DownloadStage.verifying;

  Duration? get remaining {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0 || totalBytes <= 0) return null;
    final left = totalBytes - receivedBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).round());
  }
}

/// Fetches the companion's model on first run.
///
/// **Resumable, because it has to be.** This is a multi-gigabyte transfer on a
/// phone: it will be interrupted by a tunnel, a sleeping screen, a killed
/// process. Bytes land in a `.part` file and every attempt resumes with a
/// `Range` header, so an interruption at 90% costs a reconnect rather than 2.2 GB
/// of someone's data allowance. The `.part` file is promoted to the real name
/// only after the hash matches, which means a half-written file can never be
/// mistaken for a model.
///
/// **Wi-Fi by default.** Silently spending 2.4 GB of a metered plan is not a
/// thing to do to someone. [wifiOnly] starts true and the user can override it
/// explicitly.
class ModelDownloadService extends ChangeNotifier {
  static final ModelDownloadService instance = ModelDownloadService._();

  ModelDownloadService._();

  static const MethodChannel _storage = MethodChannel('sanctuary/storage');

  /// Headroom demanded beyond the model itself, so the download does not fill
  /// the volume to the last byte and leave the database with nowhere to write.
  static const int _spareBytes = 300 * 1024 * 1024;

  final http.Client _client = http.Client();

  DownloadStatus _status = const DownloadStatus(stage: DownloadStage.idle);
  DownloadStatus get status => _status;

  /// Refuse to download over a metered connection. User-settable.
  bool wifiOnly = true;

  bool _cancelled = false;
  StreamSubscription<List<int>>? _chunks;

  /// The directory the app manages models in.
  ///
  /// App-specific external storage first: it needs no permission, is exempt from
  /// scoped-storage restrictions, is removed when the app is uninstalled, and —
  /// the reason it is first — is usually on a much larger volume than internal
  /// storage, which matters a great deal for a 2.4 GB file. Internal support
  /// directory is the fallback for devices that expose no external volume.
  Future<Directory> modelDirectory() async {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        final dir = Directory('${external.path}/models');
        await dir.create(recursive: true);
        return dir;
      }
    } catch (e) {
      debugPrint('External storage unavailable, using internal: $e');
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/models');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> fileFor(ModelRelease release) async =>
      File('${(await modelDirectory()).path}/${release.fileName}');

  /// Whether the finished model is already on disk.
  Future<bool> isInstalled(ModelRelease release) async {
    final file = await fileFor(release);
    if (!await file.exists()) return false;
    // A file of the wrong length is a leftover from an older release or a
    // download that was promoted by an earlier, less careful version.
    if (release.sizeBytes > 0) {
      return await file.length() == release.sizeBytes;
    }
    return true;
  }

  /// Bytes already fetched into the partial file, for resuming.
  Future<int> partialBytes(ModelRelease release) async {
    final part = File('${(await fileFor(release)).path}.part');
    return await part.exists() ? await part.length() : 0;
  }

  /// Free space on the volume the model would land on.
  Future<int?> freeBytes() async {
    try {
      final dir = await modelDirectory();
      final result = await _storage.invokeMethod<int>(
        'freeBytes',
        {'path': dir.path},
      );
      return result;
    } catch (e) {
      // Not fatal: a missing figure means the pre-flight check is skipped, not
      // that the download is blocked.
      debugPrint('Could not read free space: $e');
      return null;
    }
  }

  void cancel() {
    _cancelled = true;
    _chunks?.cancel();
    _emit(DownloadStatus(
      stage: DownloadStage.paused,
      receivedBytes: _status.receivedBytes,
      totalBytes: _status.totalBytes,
    ));
  }

  /// Downloads [release], resuming if a partial file is present.
  ///
  /// Never throws: every failure becomes [DownloadStage.failed] with a message
  /// written for the person reading it.
  Future<bool> download(ModelRelease release) async {
    if (_status.isActive) return false;
    _cancelled = false;

    if (!release.isConfigured) {
      // A build error, not a user error, so the user gets a plain sentence and
      // the detail goes where whoever caused it will see it.
      debugPrint(
        'ModelCatalog has no download URL set — see docs/RELEASE.md step 2.',
      );
      _fail('The companion is not available to download right now.');
      return false;
    }

    if (await isInstalled(release)) {
      _emit(DownloadStatus(
        stage: DownloadStage.ready,
        receivedBytes: release.sizeBytes,
        totalBytes: release.sizeBytes,
      ));
      return true;
    }

    if (!await _networkAllows()) return false;

    final target = await fileFor(release);
    final part = File('${target.path}.part');
    var already = await part.exists() ? await part.length() : 0;

    // A partial larger than the expected total is corrupt or from a different
    // release; starting over beats resuming into nonsense.
    if (release.sizeBytes > 0 && already >= release.sizeBytes) {
      await part.delete();
      already = 0;
    }

    if (!await _spaceAllows(release, already)) return false;

    _emit(DownloadStatus(
      stage: DownloadStage.downloading,
      receivedBytes: already,
      totalBytes: release.sizeBytes,
    ));

    // Walk the sources until one works. A host being down, rate-limiting, or
    // simply slow should not be the thing that stops someone using the app —
    // this is a one-off download that gates the entire companion.
    //
    // Switching hosts mid-file is safe *because* the bytes already on disk are
    // kept and the range continues: the mirrors are required to be identical,
    // and the SHA-256 at the end is the backstop if they are not.
    final sources = release.sources;
    for (var i = 0; i < sources.length; i++) {
      final outcome = await _attempt(release, sources[i], target, part);
      if (outcome != _Attempt.retryElsewhere) {
        return outcome == _Attempt.done;
      }
      if (i < sources.length - 1) {
        debugPrint('Source ${i + 1} failed; trying the next mirror.');
      }
    }
    return false;
  }

  /// One host's turn. Returns whether to stop, or to try the next mirror.
  Future<_Attempt> _attempt(
    ModelRelease release,
    String url,
    File target,
    File part,
  ) async {
    // Recomputed per attempt: an earlier mirror may have contributed bytes
    // before it failed, and those are kept rather than thrown away.
    var already = await part.exists() ? await part.length() : 0;

    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      if (already > 0) request.headers['Range'] = 'bytes=$already-';

      // A token is a development affordance for a gated repository and is
      // refused outright in a release build, so one committed by accident
      // cannot reach users. An APK is a zip: `unzip` and `strings` recover any
      // embedded credential in seconds, and a leaked Hugging Face read token
      // grants access to *every* private repo on the account, not just the one
      // it was minted for. Hugging Face also auto-revokes tokens it finds
      // published, which would break the download for every install at once.
      final token = release.authToken;
      if (token != null) {
        if (kReleaseMode) {
          debugPrint(
            'Refusing to send an embedded auth token from a release build. '
            'Host the model in a public repository instead.',
          );
        } else {
          request.headers['Authorization'] = 'Bearer $token';
        }
      }

      final response = await _client.send(request);

      // 206 is a granted resume. A 200 in reply to a Range request means the
      // server ignored it and is sending the whole file, so the partial must be
      // discarded rather than appended to — that is how you build a file that
      // is the right length and entirely wrong.
      if (already > 0 && response.statusCode == 200) {
        debugPrint('Server ignored Range; restarting from zero.');
        already = 0;
        if (await part.exists()) await part.delete();
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        _fail(_httpMessage(response.statusCode));
        return _Attempt.retryElsewhere;
      }

      final total = release.sizeBytes > 0
          ? release.sizeBytes
          : (response.contentLength ?? 0) + already;

      sink = part.openWrite(mode: already > 0 ? FileMode.append : FileMode.write);

      var received = already;
      var windowBytes = 0;
      var windowStart = DateTime.now();
      double? speed;
      var lastPaint = DateTime.now();

      final completer = Completer<void>();
      _chunks = response.stream.listen(
        (chunk) {
          if (_cancelled) return;
          sink!.add(chunk);
          received += chunk.length;
          windowBytes += chunk.length;

          final now = DateTime.now();
          final windowMs = now.difference(windowStart).inMilliseconds;
          if (windowMs >= 1000) {
            speed = windowBytes / (windowMs / 1000);
            windowBytes = 0;
            windowStart = now;
          }

          // Repainting on every chunk would rebuild the progress bar thousands
          // of times a second and starve the UI thread doing it.
          if (now.difference(lastPaint).inMilliseconds >= 200) {
            lastPaint = now;
            _emit(DownloadStatus(
              stage: DownloadStage.downloading,
              receivedBytes: received,
              totalBytes: total,
              bytesPerSecond: speed,
            ));
          }
        },
        onDone: completer.complete,
        onError: completer.completeError,
        cancelOnError: true,
      );

      await completer.future;
      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelled) {
        _emit(DownloadStatus(
          stage: DownloadStage.paused,
          receivedBytes: received,
          totalBytes: total,
        ));
        return _Attempt.abort;
      }

      if (release.sizeBytes > 0 && await part.length() != release.sizeBytes) {
        _fail('The download finished early and the file is incomplete. '
            'Tap retry — it will resume, not start over.');
        return _Attempt.retryElsewhere;
      }

      // A hash mismatch does not move to the next mirror. The partial has
      // already been discarded, so retrying elsewhere means re-fetching 2.4 GB
      // on the chance that a different host disagrees — and if the hash is
      // wrong the likeliest cause is a stale value in the catalog, which no
      // mirror fixes.
      if (!await _verify(part, release, total)) return _Attempt.abort;

      // Only now does it become a model. Renaming last is what guarantees a
      // half-written file is never discoverable as a real one.
      if (await target.exists()) await target.delete();
      await part.rename(target.path);

      _emit(DownloadStatus(
        stage: DownloadStage.ready,
        receivedBytes: total,
        totalBytes: total,
      ));
      return _Attempt.done;
    } on SocketException {
      _fail('Lost the connection. Tap retry — the download resumes from where '
          'it stopped.');
      return _Attempt.retryElsewhere;
    } on http.ClientException catch (e) {
      _fail('The download was interrupted (${e.message}). Tap retry to resume.');
      return _Attempt.retryElsewhere;
    } catch (e) {
      debugPrint('Model download failed: $e');
      _fail('Something went wrong downloading the companion. Tap retry to '
          'resume.');
      return _Attempt.retryElsewhere;
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // Already closed on the success path.
      }
      _chunks = null;
    }
  }

  Future<bool> _verify(File part, ModelRelease release, int total) async {
    final expected = release.sha256;
    if (expected == null) return true;

    _emit(DownloadStatus(
      stage: DownloadStage.verifying,
      receivedBytes: total,
      totalBytes: total,
    ));

    try {
      // Streamed rather than read whole: hashing 2.4 GB by loading it into
      // memory would be an immediate OOM on a device that has to fit the model
      // itself shortly afterwards.
      final digest = await part.openRead().transform(sha256).first;
      if (digest.toString() != expected.toLowerCase()) {
        await part.delete();
        _fail('The downloaded file is damaged and has been discarded. '
            'Please try again.');
        return false;
      }
    } catch (e) {
      debugPrint('Verification failed: $e');
      _fail('Could not verify the download. Please try again.');
      return false;
    }
    return true;
  }

  Future<bool> _networkAllows() async {
    try {
      final result = await Connectivity().checkConnectivity();
      if (result.contains(ConnectivityResult.none) && result.length == 1) {
        _fail('No connection. The companion needs one download to get set up, '
            'and nothing after that.');
        return false;
      }
      final onWifi = result.contains(ConnectivityResult.wifi) ||
          result.contains(ConnectivityResult.ethernet);
      if (wifiOnly && !onWifi) {
        _emit(const DownloadStatus(stage: DownloadStage.waitingForWifi));
        return false;
      }
    } catch (e) {
      // If connectivity cannot be read, let the download try and fail honestly
      // rather than blocking on a diagnostic.
      debugPrint('Connectivity check failed, continuing: $e');
    }
    return true;
  }

  Future<bool> _spaceAllows(ModelRelease release, int already) async {
    final free = await freeBytes();
    if (free == null || release.sizeBytes <= 0) return true;
    final needed = release.sizeBytes - already + _spareBytes;
    if (free < needed) {
      final shortGb = ((needed - free) / (1024 * 1024 * 1024)).toStringAsFixed(1);
      _fail('Not enough space. The companion needs about '
          '${release.readableSize} and this phone is $shortGb GB short. '
          'Freeing some space and trying again will work.');
      return false;
    }
    return true;
  }

  static String _httpMessage(int code) {
    switch (code) {
      case 401:
      case 403:
        return 'The download was refused by the server (HTTP $code). The model '
            'host is not accepting anonymous downloads.';
      case 404:
        return 'The companion model could not be found on the server '
            '(HTTP 404).';
      case 416:
        return 'The resume point was rejected by the server. Clearing the '
            'partial download and retrying will fix it.';
      default:
        return 'The server refused the download (HTTP $code).';
    }
  }

  /// Deletes both the model and any partial download.
  Future<void> removeDownload(ModelRelease release) async {
    try {
      final target = await fileFor(release);
      final part = File('${target.path}.part');
      if (await target.exists()) await target.delete();
      if (await part.exists()) await part.delete();
      _emit(const DownloadStatus(stage: DownloadStage.idle));
    } catch (e) {
      debugPrint('Could not remove model: $e');
    }
  }

  void _fail(String message) => _emit(DownloadStatus(
        stage: DownloadStage.failed,
        receivedBytes: _status.receivedBytes,
        totalBytes: _status.totalBytes,
        error: message,
      ));

  void _emit(DownloadStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _chunks?.cancel();
    _client.close();
    super.dispose();
  }
}
