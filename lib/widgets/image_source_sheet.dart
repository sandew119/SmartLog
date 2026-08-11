import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Asks where a picture should come from, and gets it.
///
/// A yard is not always the place a photograph gets taken. A log arrives,
/// somebody snaps it on the way past, and the measuring happens later at a
/// desk -- so every screen that wants an image has to accept one from the
/// gallery, not only from the camera in that moment.
///
/// Returns null when the user backs out, which is not an error.
Future<File?> pickImage(
  BuildContext context, {
  String title = "Add a photo",
  String cameraHint = "Point the camera at the log",
  String galleryHint = "Pick a photo you already took",
}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE8F5E9),
              child: Icon(Icons.photo_camera, color: Colors.green),
            ),
            title: const Text("Take a photo"),
            subtitle: Text(cameraHint),
            onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
          ),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE3F2FD),
              child: Icon(Icons.photo_library, color: Colors.blue),
            ),
            title: const Text("Choose from gallery"),
            subtitle: Text(galleryHint),
            onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (source == null || !context.mounted) return null;

  try {
    final picked = await ImagePicker().pickImage(
      source: source,
      // Full resolution. The quality gate downstream needs the real detail
      // to judge focus, and asking the picker to shrink the image first
      // would make a blurred photograph look acceptable.
      imageQuality: 100,
      preferredCameraDevice: CameraDevice.rear,
    );

    return picked == null ? null : File(picked.path);
  } catch (error) {
    if (!context.mounted) return null;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            source == ImageSource.camera
                ? "Couldn't open the camera. Check the app's permissions."
                : "Couldn't open the gallery. Check the app's permissions.",
          ),
        ),
      );

    return null;
  }
}
