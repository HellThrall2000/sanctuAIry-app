import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary/services/model_catalog.dart';
import 'package:sanctuary/services/model_download_service.dart';

/// A stand-in for a properly configured release, so the tests do not depend on
/// whoever is shipping having filled in ModelCatalog yet.
const _configured = ModelRelease(
  profileId: 'stock-gemma4-e2b',
  displayName: 'Gemma 4 E2B',
  url: 'https://models.example.com/gemma-4-E2B-it.litertlm',
  fileName: 'gemma-4-E2B-it.litertlm',
  sizeBytes: 2576980378,
  licenceNotice: 'Gemma Terms of Use.',
);

void main() {
  group('ModelRelease', () {
    test('the shipped default is a real, downloadable release', () {
      final model = ModelCatalog.defaultModel;
      expect(model.isConfigured, isTrue);
      expect(model.url, startsWith('https://'));
      expect(model.sizeBytes, greaterThan(0));

      // Size and hash come from the host's own LFS metadata and are what the
      // free-space check and the integrity check run on. A zeroed or stale hash
      // would make every download look corrupt and be deleted on arrival.
      expect(model.sha256, isNotNull);
      expect(model.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('the shipped release is served from R2, with no mirrors', () {
      final model = ModelCatalog.defaultModel;
      expect(model.url, contains('r2.dev'));
      expect(model.mirrors, isEmpty);
      expect(model.sources, [model.url]);
    });

    test('mirrors, when present, are tried after the primary', () {
      // The mechanism is unused by the shipped catalog but still live code:
      // adding a URL must extend the source list in order, never reorder it.
      const mirrored = ModelRelease(
        profileId: 'x',
        displayName: 'x',
        url: 'https://primary.example.com/m.litertlm',
        mirrors: ['https://backup.example.com/m.litertlm'],
        fileName: 'm.litertlm',
        sizeBytes: 1,
        licenceNotice: '',
      );
      expect(mirrored.sources, [
        'https://primary.example.com/m.litertlm',
        'https://backup.example.com/m.litertlm',
      ]);
    });

    test('no credential is embedded in the shipped release', () {
      // An APK is a zip; anything here is recoverable with `strings`. The
      // download service also refuses to send a token in release mode, but the
      // catalog should never carry one in the first place.
      expect(ModelCatalog.defaultModel.authToken, isNull);
    });

    test('a placeholder URL is detected rather than attempted', () {
      const placeholder = ModelRelease(
        profileId: 'x',
        displayName: 'x',
        url: 'https://REPLACE_ME.example.com/model.litertlm',
        fileName: 'x.litertlm',
        sizeBytes: 1,
        licenceNotice: '',
      );
      expect(placeholder.isConfigured, isFalse);
      expect(_configured.isConfigured, isTrue);
    });

    test('an empty URL is not configured', () {
      const blank = ModelRelease(
        profileId: 'x',
        displayName: 'x',
        url: '',
        fileName: 'x.litertlm',
        sizeBytes: 1,
        licenceNotice: '',
      );
      expect(blank.isConfigured, isFalse);
    });

    test('size reads in the units a person uses', () {
      expect(_configured.readableSize, '2.4 GB');
      expect(
        const ModelRelease(
          profileId: 'x',
          displayName: 'x',
          url: 'https://e.com/x',
          fileName: 'x.litertlm',
          sizeBytes: 512 * 1024 * 1024,
          licenceNotice: '',
        ).readableSize,
        '512 MB',
      );
    });

    test('catalog lookup is by profile id, so the download picks the persona',
        () {
      expect(ModelCatalog.byProfileId('stock-gemma4-e2b'), isNotNull);
      expect(ModelCatalog.byProfileId('not-a-model'), isNull);
    });
  });

  group('DownloadStatus', () {
    test('fraction is a real fraction', () {
      const half = DownloadStatus(
        stage: DownloadStage.downloading,
        receivedBytes: 50,
        totalBytes: 100,
      );
      expect(half.fraction, 0.5);
    });

    test('an unknown total does not divide by zero', () {
      const unknown = DownloadStatus(stage: DownloadStage.downloading);
      expect(unknown.fraction, 0);
      expect(unknown.remaining, isNull);
    });

    test('fraction cannot exceed one', () {
      // A server that sends more than advertised must not drive the progress
      // bar past its end.
      const over = DownloadStatus(
        stage: DownloadStage.downloading,
        receivedBytes: 150,
        totalBytes: 100,
      );
      expect(over.fraction, 1.0);
    });

    test('estimates time from the measured speed', () {
      const status = DownloadStatus(
        stage: DownloadStage.downloading,
        receivedBytes: 0,
        totalBytes: 1000,
        bytesPerSecond: 100,
      );
      expect(status.remaining, const Duration(seconds: 10));
    });

    test('no estimate before there is a speed to estimate from', () {
      const status = DownloadStatus(
        stage: DownloadStage.downloading,
        receivedBytes: 10,
        totalBytes: 1000,
      );
      expect(status.remaining, isNull);
    });

    test('a finished download has nothing remaining', () {
      const done = DownloadStatus(
        stage: DownloadStage.downloading,
        receivedBytes: 1000,
        totalBytes: 1000,
        bytesPerSecond: 100,
      );
      expect(done.remaining, Duration.zero);
    });

    test('only downloading and verifying count as active', () {
      // The setup screen hides "Set up later" while active — offering to defer
      // a transfer that is already running invites a mis-tap that throws away
      // however much has been fetched.
      for (final stage in DownloadStage.values) {
        final active = DownloadStatus(stage: stage).isActive;
        expect(
          active,
          stage == DownloadStage.downloading ||
              stage == DownloadStage.verifying,
          reason: '$stage',
        );
      }
    });
  });
}
