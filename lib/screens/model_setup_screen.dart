import 'package:flutter/material.dart';

import '../services/model_catalog.dart';
import '../services/model_download_service.dart';
import '../services/usage_metrics.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/organic/organic.dart';

/// First run: fetches the companion before the app can be used.
///
/// **Why this screen has to explain itself.** It asks for a 2.4 GB download
/// before the user has seen anything, which is an enormous request from a
/// stranger. So it says what the download is, why it is that size, and what the
/// user gets for it — that the companion then runs entirely on their phone, with
/// nothing they say ever leaving it. That property is the whole reason the file
/// is large, and stating it turns the size from a cost into the point.
///
/// Shown only when no model is present. Once one is on disk this screen is never
/// seen again.
///
/// **It can be skipped, and that is deliberate.** The diary, the lockbox and the
/// soundscapes need no model at all, and holding them behind a 2.4 GB download —
/// on a phone that may be on mobile data, or nearly full — would be refusing to
/// show someone the app they just installed. Deferring is remembered, so the
/// choice is not re-litigated at every launch; the companion tab explains how to
/// finish setup whenever they want it.
class ModelSetupScreen extends StatefulWidget {
  /// Called once a model is on disk and verified.
  final VoidCallback onReady;

  /// Called when the user chooses to deal with this later.
  final VoidCallback onDefer;

  const ModelSetupScreen({
    super.key,
    required this.onReady,
    required this.onDefer,
  });

  @override
  State<ModelSetupScreen> createState() => _ModelSetupScreenState();
}

class _ModelSetupScreenState extends State<ModelSetupScreen> {
  final _downloads = ModelDownloadService.instance;
  static const _release = ModelCatalog.defaultModel;

  int? _freeBytes;
  int _resumeFrom = 0;

  @override
  void initState() {
    super.initState();
    _downloads.addListener(_onChanged);
    _probe();
  }

  @override
  void dispose() {
    _downloads.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (_downloads.status.stage == DownloadStage.ready) {
      UsageMetrics.instance.recordModelDownloaded();
      widget.onReady();
    }
  }

  Future<void> _probe() async {
    final free = await _downloads.freeBytes();
    final partial = await _downloads.partialBytes(_release);
    if (!mounted) return;
    setState(() {
      _freeBytes = free;
      _resumeFrom = partial;
    });
  }

  Future<void> _start() async {
    await _downloads.download(_release);
    if (mounted) await _probe();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final status = _downloads.status;

    return Scaffold(
      backgroundColor: t.bgApp,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Organic.space6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Arch(color: t.accentBg, surface: t.bgSurface),
                  const SizedBox(height: Organic.space6),
                  Text('One download, then never again',
                      style: OrganicText.h2(t)),
                  const SizedBox(height: Organic.space3),
                  Text(
                    'Your companion is a ${_release.readableSize} model that '
                    'runs on this phone. Download it once and everything after '
                    'that happens offline.',
                    style: OrganicText.body(t),
                  ),
                  const SizedBox(height: Organic.space6),
                  ..._body(t, status),
                  if (!status.isActive) ...[
                    const SizedBox(height: Organic.space2),
                    Center(
                      child: OrganicButton(
                        label: 'Set up later',
                        variant: OrganicButtonVariant.ghost,
                        fontSize: 13,
                        onPressed: widget.onDefer,
                      ),
                    ),
                    const SizedBox(height: Organic.space2),
                    Text(
                      'Your diary and the soundscapes work without it.',
                      style: OrganicText.muted(t).copyWith(fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: Organic.space6),
                  Text(
                    _release.licenceNotice,
                    style: OrganicText.muted(t).copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(SanctuaryTokens t, DownloadStatus status) {
    switch (status.stage) {
      case DownloadStage.downloading:
      case DownloadStage.verifying:
        return _progress(t, status);

      case DownloadStage.waitingForWifi:
        return [
          _Notice(
            tone: _NoticeTone.info,
            title: 'Waiting for Wi-Fi',
            detail: 'Set to Wi-Fi only, to save your mobile data.',
          ),
          const SizedBox(height: Organic.space4),
          _wifiToggle(t),
          OrganicButton(
            label: 'Download anyway',
            block: true,
            variant: OrganicButtonVariant.secondary,
            onPressed: () {
              _downloads.wifiOnly = false;
              _start();
            },
          ),
        ];

      case DownloadStage.failed:
        return [
          _Notice(
            tone: _NoticeTone.error,
            title: 'Download stopped',
            detail: status.error ?? 'Something went wrong.',
          ),
          const SizedBox(height: Organic.space4),
          OrganicButton(
            label: _resumeFrom > 0 ? 'Resume download' : 'Try again',
            block: true,
            onPressed: _start,
          ),
        ];

      case DownloadStage.paused:
        return [
          _bar(t, status),
          const SizedBox(height: Organic.space3),
          Text('Paused at ${_percent(status)}. Nothing is lost.',
              style: OrganicText.muted(t)),
          OrganicButton(label: 'Resume', block: true, onPressed: _start),
        ];

      case DownloadStage.ready:
        return [
          _Notice(
            tone: _NoticeTone.info,
            title: 'Ready',
            detail: 'Opening your sanctuary…',
          ),
        ];

      case DownloadStage.idle:
        return _idle(t);
    }
  }

  List<Widget> _idle(SanctuaryTokens t) {
    final free = _freeBytes;
    final short = free != null && free < _release.sizeBytes + (300 << 20);

    return [
      _Row(label: 'Download size', value: _release.readableSize),
      if (free != null)
        _Row(label: 'Free on this phone', value: _gb(free)),
      if (_resumeFrom > 0)
        _Row(label: 'Already downloaded', value: _gb(_resumeFrom)),
      const SizedBox(height: Organic.space4),
      if (short)
        _Notice(
          tone: _NoticeTone.warning,
          title: 'Not much room',
          detail: 'Free up some space first, or the download will not finish.',
        ),
      _wifiToggle(t),
      OrganicButton(
        label: _resumeFrom > 0
            ? 'Resume download'
            : 'Download the companion',
        block: true,
        onPressed: _start,
      ),
    ];
  }

  List<Widget> _progress(SanctuaryTokens t, DownloadStatus status) {
    final verifying = status.stage == DownloadStage.verifying;
    return [
      _bar(t, status),
      const SizedBox(height: Organic.space3),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            verifying ? 'Checking the download…' : _percent(status),
            style: OrganicText.body(t),
          ),
          if (!verifying)
            Text(
              '${_gb(status.receivedBytes)} of ${_gb(status.totalBytes)}',
              style: OrganicText.muted(t),
            ),
        ],
      ),
      if (!verifying && status.remaining != null) ...[
        const SizedBox(height: Organic.space1),
        Text(
          '${_speed(status.bytesPerSecond)} · about '
          '${_eta(status.remaining!)} left',
          style: OrganicText.muted(t),
        ),
      ],
      const SizedBox(height: Organic.space4),
      if (!verifying)
        OrganicButton(
          label: 'Pause',
          block: true,
          variant: OrganicButtonVariant.secondary,
          onPressed: _downloads.cancel,
        ),
    ];
  }

  Widget _wifiToggle(SanctuaryTokens t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Organic.space2),
      child: Row(
        children: [
          Expanded(
            child: Text('Wi-Fi only', style: OrganicText.body(t)),
          ),
          Switch(
            value: _downloads.wifiOnly,
            activeThumbColor: t.accentBg,
            onChanged: (v) => setState(() => _downloads.wifiOnly = v),
          ),
        ],
      ),
    );
  }

  Widget _bar(SanctuaryTokens t, DownloadStatus status) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Organic.radiusPill),
      child: LinearProgressIndicator(
        value: status.stage == DownloadStage.verifying ? null : status.fraction,
        minHeight: 10,
        backgroundColor: t.border,
        valueColor: AlwaysStoppedAnimation(t.accentBg),
      ),
    );
  }

  static String _percent(DownloadStatus s) =>
      '${(s.fraction * 100).toStringAsFixed(0)}%';

  static String _gb(int bytes) {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    return '${(bytes / mb).round()} MB';
  }

  static String _speed(double? bytesPerSecond) {
    if (bytesPerSecond == null) return '';
    const mb = 1024 * 1024;
    if (bytesPerSecond >= mb) {
      return '${(bytesPerSecond / mb).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSecond / 1024).round()} KB/s';
  }

  static String _eta(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: Organic.space2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: OrganicText.muted(t)),
          Text(value, style: OrganicText.body(t)),
        ],
      ),
    );
  }
}

enum _NoticeTone { info, warning, error }

class _Notice extends StatelessWidget {
  final _NoticeTone tone;
  final String title;
  final String detail;

  const _Notice({
    required this.tone,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accent = switch (tone) {
      _NoticeTone.info => t.accentText,
      _NoticeTone.warning => Organic.accent600,
      _NoticeTone.error => Organic.danger,
    };

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Organic.space2),
      padding: const EdgeInsets.all(Organic.space4),
      decoration: BoxDecoration(
        color: t.bgSurface,
        borderRadius: BorderRadius.circular(Organic.radiusMd),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: OrganicText.h5(t).copyWith(color: accent)),
          const SizedBox(height: Organic.space1),
          Text(detail, style: OrganicText.body(t)),
        ],
      ),
    );
  }
}

/// The app mark, drawn rather than shipped as an asset so it follows the theme.
class _Arch extends StatelessWidget {
  final Color color;
  final Color surface;

  const _Arch({required this.color, required this.surface});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Organic.radiusLg),
      ),
      child: Center(
        child: Container(
          width: 27,
          height: 38,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}
