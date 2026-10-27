import 'package:flutter/material.dart';

/// Related outlines for different sizes and roles, not one radius everywhere.
class StudyShapes {
  static const small = 8.0;
  static const card = 16.0;
  static const reader = 24.0;
  static const navigation = 28.0;
  static const readerInset = 10.0;
  static const cardBorder = BorderRadius.all(Radius.circular(card));
  static const readerBorder = BorderRadius.all(Radius.circular(reader));
}
