import 'package:file_picker/file_picker.dart';

class SelectedPdf {
  const SelectedPdf({
    required this.name,
    required this.size,
    required this.openRead,
  });
  final String name;
  final int size;
  final Stream<List<int>> Function() openRead;
}

abstract interface class PdfPicker {
  Future<SelectedPdf?> pick();
}

class PlatformPdfPicker implements PdfPicker {
  @override
  Future<SelectedPdf?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (file == null) return null;
    final size = await file.length();
    if (size == null) throw StateError('Cannot read file size');
    return SelectedPdf(
      name: file.name,
      size: size,
      openRead: file.readAsByteStream,
    );
  }
}
