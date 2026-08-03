/// What the app downloads on first run, and where from.
///
/// **Why the model is not in the package.** The companion is a ~2.5 GB
/// `.litertlm`. Play caps an app bundle far below that, so it cannot ship
/// inside the APK; and while Play Asset Delivery raises the ceiling, an
/// on-demand pack of this size sits at the edge of what it will carry and has no
/// iOS equivalent at all. A plain first-run download is what the on-device LLM
/// apps that actually shipped do, including Google's own AI Edge Gallery, and it
/// is the only route that works the same on both stores.
///
/// **Why not Firebase Storage.** The obvious answer, given the rest of this
/// feature, and it does not work: the Spark plan allows on the order of 1 GB of
/// egress a day. One user downloading one model exhausts it, and the second user
/// that day gets a failure.
///
/// **Hosted on Cloudflare R2.** Zero egress fees, and it answers `Range`
/// requests with a `206`, which is what makes [ModelDownloadService]'s resume
/// work at all.
///
/// Measured serving the test tablet: R2 has yet to be timed on-device, but the
/// two hosts it replaced managed **2.5–3.9 MB/s (OCI Object Storage,
/// ap-hyderabad-1)** and **751 KB/s with a three-minute stall at 93%
/// (Hugging Face)**. Both worked; neither was comfortable for a 2.4 GB
/// first-run download.
///
/// **The Gemma licence travels with the file.** Its terms permit redistribution
/// provided recipients receive a copy — which is what
/// [ModelRelease.licenceNotice] puts in front of the user before the download
/// starts. (Google's own `google/` and `litert-community/` Hugging Face
/// repositories are gated and return 401 to anonymous clients, so linking those
/// directly never works; hosting your own copy is both the practical and the
/// licensed route.)
///
/// **What does not work:** GitHub Releases caps a single asset at 2 GiB and this
/// file is larger; Git LFS gives 1 GB of bandwidth a month; Google Drive
/// interposes a virus-scan interstitial on large files and serves no usable
/// ranges.
///
/// [ModelRelease.authToken] exists only for development against a gated
/// repository. Never ship a build with a token in it.
library;

/// One downloadable model.
class ModelRelease {
  /// Matches `ModelProfile.id`, so the downloaded file runs under the right
  /// persona, sampler and repair settings.
  final String profileId;

  final String displayName;

  /// Direct URL. Must answer `Range` requests, or a dropped download restarts
  /// from zero — see [ModelDownloadService].
  final String url;

  /// Alternative sources, tried in order when [url] fails.
  ///
  /// **Every mirror must be byte-identical**, because a download is resumed
  /// across whichever host answers — bytes already on disk are kept and the
  /// range continues from the next one. A mirror holding a different build
  /// would produce a file that is the right length and quietly wrong. The
  /// SHA-256 check at the end catches it, but the cost is a discarded 2.4 GB
  /// download, so upload the same file rather than re-exporting per host.
  final List<String> mirrors;

  /// File name on disk. Keep the `.litertlm` suffix: model discovery filters on
  /// it.
  final String fileName;

  /// Exact size in bytes. Used for the progress bar and, more importantly, for
  /// the free-space check before a multi-gigabyte write begins.
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the finished file, or null to skip verification.
  ///
  /// Worth the minute it costs. A truncated or corrupted model does not fail
  /// politely in Dart — it aborts inside `nativeCreateEngine`, taking the process
  /// with it and producing a crash that looks exactly like the low-memory kills
  /// this project spent weeks chasing.
  final String? sha256;

  /// Shown before the download starts, and again on the licences screen.
  final String licenceNotice;

  const ModelRelease({
    required this.profileId,
    required this.displayName,
    required this.url,
    required this.fileName,
    required this.sizeBytes,
    required this.licenceNotice,
    this.mirrors = const [],
    this.sha256,
    this.authToken,
  });

  /// [url] first, then [mirrors]. What the downloader walks.
  List<String> get sources => [url, ...mirrors];

  /// Optional bearer token, for developing against a **gated** repository.
  ///
  /// Not needed for a public repo, and it buys nothing there: Hugging Face
  /// serves public files at full CDN speed anonymously, and a token changes
  /// authentication, not throughput.
  ///
  /// [ModelDownloadService] refuses to send this from a release build, so a
  /// token committed by accident cannot reach users. That guard exists because
  /// an APK is a zip file — `unzip` plus `strings` recovers any embedded
  /// credential in seconds — and a leaked Hugging Face read token grants access
  /// to every private repository on the account, not merely the one it was
  /// created for.
  final String? authToken;

  /// Rounded size for UI, e.g. "2.4 GB".
  String get readableSize {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (sizeBytes >= gb) {
      return '${(sizeBytes / gb).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / mb).round()} MB';
  }

  bool get isConfigured => url.isNotEmpty && !url.contains('REPLACE_ME');
}

/// The releases this build knows how to fetch.
abstract final class ModelCatalog {
  /// The model a fresh install downloads.
  ///
  /// Hosted on Hugging Face, public and ungated, so it downloads with no token
  /// and no account. Verified against the live endpoint: an anonymous ranged GET
  /// returns `206` with `content-range: bytes 0-99/2588147712`, which is what
  /// makes resume work.
  ///
  /// **The size and hash were not guessed.** Both come from the repository's own
  /// LFS metadata:
  ///
  /// ```
  /// curl -s https://huggingface.co/api/models/Padmanava/gemma_4_mobile_project/tree/main/litert_v2
  /// ```
  ///
  /// whose `lfs.oid` is a plain SHA-256 of the file contents — confirmed by
  /// hashing a small LFS file and comparing. So the checksum below can be
  /// re-derived at any time without downloading 2.4 GB. If you re-upload the
  /// model, re-run that command and update **both** fields: the size drives the
  /// free-space pre-flight check, and a stale hash would make every download
  /// look corrupt.
  static const ModelRelease defaultModel = ModelRelease(
    profileId: 'gemma4-e2b-stock',
    displayName: 'Gemma 4 E2B',
    // Cloudflare R2, public development URL. Verified anonymously: `206` with
    // `content-range: bytes 0-99/2588147712`, and byte-identical to the local
    // model at three offsets.
    //
    // **This is the r2.dev development domain, which Cloudflare rate-limits and
    // documents as unsuitable for production.** It is correct for testing and
    // for a small beta; before a real launch, attach a Custom Domain to the
    // bucket and change this URL. Egress is free either way — the domain is the
    // only cost, and it removes the throttle.
    url: 'https://pub-de0460c2f1f04db5b33d4a08860d134d.r2.dev/'
        'gemma-4-E2B-it.litertlm',

    // No mirrors: R2 is the single source of truth for the model.
    //
    // The fallback mechanism remains in ModelDownloadService and costs nothing
    // while unused — add a URL here and it is tried automatically when the
    // primary fails. Any mirror added must be **byte-identical**, because a
    // download resumes against whichever host answers.
    fileName: 'gemma-4-E2B-it.litertlm',
    sizeBytes: 2588147712, // 2.41 GB
    sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    licenceNotice:
        'Gemma is provided by Google under the Gemma Terms of Use. By '
        'downloading you agree to those terms and to the Gemma Prohibited Use '
        'Policy.',
  );

  static const List<ModelRelease> all = [defaultModel];

  static ModelRelease? byProfileId(String id) {
    for (final release in all) {
      if (release.profileId == id) return release;
    }
    return null;
  }
}
