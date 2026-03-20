import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_picker/src/api/file_picker_types.dart';
import 'package:file_picker/src/api/file_picker_result.dart';
import 'package:file_picker/src/api/platform_file.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:path/path.dart' as p;
import 'package:web/web.dart';

class FilePickerWeb extends FilePickerPlatform {
  late Element _target;
  final String _kFilePickerInputsDomId = '__file_picker_web-file-input';

  final int _readStreamChunkSize = 1000 * 1000; // 1 MB

  FilePickerWeb._() {
    _target = _ensureInitialized(_kFilePickerInputsDomId);
  }

  static void registerWith(Registrar registrar) {
    FilePickerPlatform.instance = FilePickerWeb._();
  }

  /// Initializes a DOM container where we can host input elements.
  /// Pinned to center of viewport so iOS renders the file picker sheet
  /// from the bottom (natural iOS behavior) regardless of where the
  /// trigger button is on screen.
  Element _ensureInitialized(String id) {
    Element? target = document.querySelector('#$id');
    if (target == null) {
      final Element targetElement = document.createElement(
        'flt-file-picker-inputs',
      )..id = id;

      // Pin to center of viewport:
      // - position: fixed so it's always relative to viewport, not page scroll
      // - top: 50% / left: 50% so iOS sees input in the middle and renders
      //   the action sheet from the bottom (standard iOS UX)
      // - width/height: 1px minimum so the element has a real position in DOM
      // - opacity: 0 + overflow: hidden to keep it invisible
      targetElement.setAttribute(
        'style',
        'position: fixed; top: 50%; left: 50%; width: 1px; height: 1px; opacity: 0; overflow: hidden;',
      );

      document.querySelector('body')!.children.add(targetElement);
      target = targetElement;
    }
    return target;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    Function(FilePickerStatus)? onFileLoading,
    bool withData = true,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    int compressionQuality = 0,
  }) async {
    if (type != FileType.custom && (allowedExtensions?.isNotEmpty ?? false)) {
      throw Exception(
        'You are setting a type [$type]. Custom extension filters are only allowed with FileType.custom, please change it or remove filters.',
      );
    }

    Completer<List<PlatformFile>?>? filesCompleter =
        Completer<List<PlatformFile>?>();

    String accept = _fileType(type, allowedExtensions);
    HTMLInputElement uploadInput = HTMLInputElement();
    uploadInput.type = 'file';
    uploadInput.draggable = true;
    uploadInput.multiple = allowMultiple;
    uploadInput.accept = accept;

    // Use opacity: 0 instead of display: none so the element has a real
    // position in the DOM. display: none removes the element from layout,
    // causing iOS to lose track of where to anchor the picker sheet.
    uploadInput.style.opacity = '0';
    uploadInput.style.position = 'fixed';
    uploadInput.style.width = '1px';
    uploadInput.style.height = '1px';

    bool changeEventTriggered = false;

    if (onFileLoading != null) {
      onFileLoading(FilePickerStatus.picking);
    }

    void changeEventListener(Event e) async {
      if (changeEventTriggered) {
        return;
      }
      changeEventTriggered = true;

      final FileList files = uploadInput.files!;
      final List<PlatformFile> pickedFiles = [];

      void addPickedFile(
        File file,
        Uint8List? bytes,
        String? path,
        Stream<List<int>>? readStream,
      ) {
        String? blobUrl;
        if (bytes != null && bytes.isNotEmpty) {
          final blob = Blob(
            [bytes.toJS].toJS,
            BlobPropertyBag(type: file.type),
          );

          blobUrl = URL.createObjectURL(blob);
        }
        pickedFiles.add(
          PlatformFile(
            name: file.name,
            path: path ?? blobUrl,
            size: bytes != null ? bytes.length : file.size,
            bytes: bytes,
            readStream: readStream,
          ),
        );

        if (pickedFiles.length >= files.length) {
          if (onFileLoading != null) {
            onFileLoading(FilePickerStatus.done);
          }
          filesCompleter?.complete(pickedFiles);
        }
      }

      for (int i = 0; i < files.length; i++) {
        final File? file = files.item(i);
        if (file == null) {
          continue;
        }

        if (withReadStream) {
          addPickedFile(file, null, null, _openFileReadStream(file));
          continue;
        }

        if (!withData) {
          final FileReader reader = FileReader();
          reader.onLoadEnd.listen((e) {
            String? result = (reader.result as JSString?)?.toDart;
            addPickedFile(file, null, result, null);
          });
          reader.readAsDataURL(file);
          continue;
        }

        final syncCompleter = Completer<void>();
        final FileReader reader = FileReader();
        reader.onLoadEnd.listen((e) {
          ByteBuffer? byteBuffer = (reader.result as JSArrayBuffer?)?.toDart;
          addPickedFile(file, byteBuffer?.asUint8List(), null, null);
          syncCompleter.complete();
        });
        reader.readAsArrayBuffer(file);
        if (readSequential) {
          await syncCompleter.future;
        }
      }
    }

    void cancelledEventListener(Event _) {
      window.removeEventListener('focus', cancelledEventListener.toJS);

      // This listener is called before the input changed event,
      // and the `uploadInput.files` value is still null
      // Wait for results from js to dart
      Future.delayed(Duration(seconds: 1)).then((value) {
        if (!changeEventTriggered) {
          changeEventTriggered = true;
          filesCompleter?.complete(null);
        }
      });
    }

    uploadInput.onChange.listen(changeEventListener);
    uploadInput.addEventListener('change', changeEventListener.toJS);
    uploadInput.addEventListener('cancel', cancelledEventListener.toJS);

    if (cancelUploadOnWindowBlur) {
      // Listen focus event for cancelled
      window.addEventListener('focus', cancelledEventListener.toJS);
    }

    // Clear any previous input elements
    Node? firstChild = _target.firstChild;
    while (firstChild != null) {
      _target.removeChild(firstChild);
      firstChild = _target.firstChild;
    }

    // Add input to DOM and click — input must stay in DOM until user finishes
    // picking so iOS can correctly anchor the sheet position
    _target.children.add(uploadInput);
    uploadInput.click();

    // Wait for user to finish picking before cleaning up DOM
    final List<PlatformFile>? files = await filesCompleter.future;
    filesCompleter = null;

    // Cleanup input from DOM after result is received
    firstChild = _target.firstChild;
    while (firstChild != null) {
      _target.removeChild(firstChild);
      firstChild = _target.firstChild;
    }

    return files == null ? null : FilePickerResult(files);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    if (bytes == null || bytes.isEmpty) {
      throw ArgumentError(
        'The bytes are required when saving a file on the web.',
      );
    }

    if (fileName == null || fileName.isEmpty) {
      throw ArgumentError(
        'A file name is required when saving a file on the web.',
      );
    }

    if (p.extension(fileName).isEmpty) {
      throw ArgumentError(
        'The file name should include a valid file extension.',
      );
    }

    final blob = Blob([bytes.toJS].toJS);
    final url = URL.createObjectURL(blob);

    // Start a download by using a click event on an anchor element that contains the Blob.
    HTMLAnchorElement()
      ..href = url
      ..target =
          'blank' // Always open the file in a new tab.
      ..download = fileName
      ..click();

    // Release the Blob URL after the download started.
    URL.revokeObjectURL(url);
    return null;
  }

  static String _fileType(FileType type, List<String>? allowedExtensions) {
    switch (type) {
      case FileType.any:
        return '';

      case FileType.audio:
        return 'audio/*';

      case FileType.image:
        return 'image/*';

      case FileType.video:
        return 'video/*';

      case FileType.media:
        return 'video/*|image/*';

      case FileType.custom:
        return allowedExtensions!.fold(
          '',
          (prev, next) => '${prev.isEmpty ? '' : '$prev,'} .$next',
        );
    }
  }

  Stream<List<int>> _openFileReadStream(File file) async* {
    final reader = FileReader();

    int start = 0;
    while (start < file.size) {
      final end = start + _readStreamChunkSize > file.size
          ? file.size
          : start + _readStreamChunkSize;
      final blob = file.slice(start, end);
      reader.readAsArrayBuffer(blob);
      await EventStreamProviders.loadEvent.forTarget(reader).first;
      final JSAny? readerResult = reader.result;
      if (readerResult == null) {
        continue;
      }

      // Handle the ArrayBuffer type. This maps to a `ByteBuffer` in Dart.
      if (readerResult.isA<JSArrayBuffer>()) {
        yield (readerResult as JSArrayBuffer).toDart.asUint8List();
        start += _readStreamChunkSize;
        continue;
      }

      if (readerResult.isA<JSArray>()) {
        // Assume this is a List<int>.
        yield (readerResult as JSArray).toDart.cast<int>();
        start += _readStreamChunkSize;
      }
    }
  }
}
