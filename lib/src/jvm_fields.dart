/// Reading and writing instance and static fields, for every JNI type.
library;

import 'dart:ffi';

import 'errors.dart';
import 'java_ref.dart';
import 'jni_slots.dart';
import 'jvm.dart';
import 'native_types.dart';
import 'signatures.dart';

/// Field access.
///
/// As with calls, the accessor name states the field's *type*; the
/// descriptor-driven [getFieldByType] / [setFieldByType] pair picks it for you.
extension JvmFields on Jvm {
  // --- Instance getters ----------------------------------------------------

  JavaRef getObjectField(JavaRef object, Pointer<Void> field) => JavaRef(
    this,
    _getObject(JniFn.getObjectField, object.pointer, field),
    JavaRefKind.local,
  );

  bool getBooleanField(JavaRef object, Pointer<Void> field) =>
      _getBool(JniFn.getBooleanField, object.pointer, field);

  int getByteField(JavaRef object, Pointer<Void> field) =>
      _getByte(JniFn.getByteField, object.pointer, field);

  int getCharField(JavaRef object, Pointer<Void> field) =>
      _getChar(JniFn.getCharField, object.pointer, field);

  int getShortField(JavaRef object, Pointer<Void> field) =>
      _getShort(JniFn.getShortField, object.pointer, field);

  int getIntField(JavaRef object, Pointer<Void> field) =>
      _getInt(JniFn.getIntField, object.pointer, field);

  int getLongField(JavaRef object, Pointer<Void> field) =>
      _getLong(JniFn.getLongField, object.pointer, field);

  double getFloatField(JavaRef object, Pointer<Void> field) =>
      _getFloat(JniFn.getFloatField, object.pointer, field);

  double getDoubleField(JavaRef object, Pointer<Void> field) =>
      _getDouble(JniFn.getDoubleField, object.pointer, field);

  // --- Instance setters ----------------------------------------------------

  void setObjectField(JavaRef object, Pointer<Void> field, JavaRef? value) =>
      _setObject(
        JniFn.setObjectField,
        object.pointer,
        field,
        value == null ? nullptr : value.pointer,
      );

  void setBooleanField(JavaRef object, Pointer<Void> field, bool value) =>
      _setBool(JniFn.setBooleanField, object.pointer, field, value);

  void setByteField(JavaRef object, Pointer<Void> field, int value) =>
      _setByte(JniFn.setByteField, object.pointer, field, value);

  void setCharField(JavaRef object, Pointer<Void> field, int value) =>
      _setChar(JniFn.setCharField, object.pointer, field, value);

  void setShortField(JavaRef object, Pointer<Void> field, int value) =>
      _setShort(JniFn.setShortField, object.pointer, field, value);

  void setIntField(JavaRef object, Pointer<Void> field, int value) =>
      _setInt(JniFn.setIntField, object.pointer, field, value);

  void setLongField(JavaRef object, Pointer<Void> field, int value) =>
      _setLong(JniFn.setLongField, object.pointer, field, value);

  void setFloatField(JavaRef object, Pointer<Void> field, double value) =>
      _setFloat(JniFn.setFloatField, object.pointer, field, value);

  void setDoubleField(JavaRef object, Pointer<Void> field, double value) =>
      _setDouble(JniFn.setDoubleField, object.pointer, field, value);

  // --- Static getters ------------------------------------------------------

  JavaRef getStaticObjectField(JavaRef clazz, Pointer<Void> field) => JavaRef(
    this,
    _getObject(JniFn.getStaticObjectField, clazz.pointer, field),
    JavaRefKind.local,
  );

  bool getStaticBooleanField(JavaRef clazz, Pointer<Void> field) =>
      _getBool(JniFn.getStaticBooleanField, clazz.pointer, field);

  int getStaticByteField(JavaRef clazz, Pointer<Void> field) =>
      _getByte(JniFn.getStaticByteField, clazz.pointer, field);

  int getStaticCharField(JavaRef clazz, Pointer<Void> field) =>
      _getChar(JniFn.getStaticCharField, clazz.pointer, field);

  int getStaticShortField(JavaRef clazz, Pointer<Void> field) =>
      _getShort(JniFn.getStaticShortField, clazz.pointer, field);

  int getStaticIntField(JavaRef clazz, Pointer<Void> field) =>
      _getInt(JniFn.getStaticIntField, clazz.pointer, field);

  int getStaticLongField(JavaRef clazz, Pointer<Void> field) =>
      _getLong(JniFn.getStaticLongField, clazz.pointer, field);

  double getStaticFloatField(JavaRef clazz, Pointer<Void> field) =>
      _getFloat(JniFn.getStaticFloatField, clazz.pointer, field);

  double getStaticDoubleField(JavaRef clazz, Pointer<Void> field) =>
      _getDouble(JniFn.getStaticDoubleField, clazz.pointer, field);

  // --- Static setters ------------------------------------------------------

  void setStaticObjectField(
    JavaRef clazz,
    Pointer<Void> field,
    JavaRef? value,
  ) => _setObject(
    JniFn.setStaticObjectField,
    clazz.pointer,
    field,
    value == null ? nullptr : value.pointer,
  );

  void setStaticBooleanField(JavaRef clazz, Pointer<Void> field, bool value) =>
      _setBool(JniFn.setStaticBooleanField, clazz.pointer, field, value);

  void setStaticByteField(JavaRef clazz, Pointer<Void> field, int value) =>
      _setByte(JniFn.setStaticByteField, clazz.pointer, field, value);

  void setStaticCharField(JavaRef clazz, Pointer<Void> field, int value) =>
      _setChar(JniFn.setStaticCharField, clazz.pointer, field, value);

  void setStaticShortField(JavaRef clazz, Pointer<Void> field, int value) =>
      _setShort(JniFn.setStaticShortField, clazz.pointer, field, value);

  void setStaticIntField(JavaRef clazz, Pointer<Void> field, int value) =>
      _setInt(JniFn.setStaticIntField, clazz.pointer, field, value);

  void setStaticLongField(JavaRef clazz, Pointer<Void> field, int value) =>
      _setLong(JniFn.setStaticLongField, clazz.pointer, field, value);

  void setStaticFloatField(JavaRef clazz, Pointer<Void> field, double value) =>
      _setFloat(JniFn.setStaticFloatField, clazz.pointer, field, value);

  void setStaticDoubleField(JavaRef clazz, Pointer<Void> field, double value) =>
      _setDouble(JniFn.setStaticDoubleField, clazz.pointer, field, value);

  // --- Dispatch by descriptor ----------------------------------------------

  /// Reads a field, returning the natural Dart type for [descriptor].
  Object? getFieldByType(
    String descriptor,
    JavaRef receiver,
    Pointer<Void> field, {
    required bool static,
  }) {
    switch (descriptor) {
      case JniType.boolean:
        return static
            ? getStaticBooleanField(receiver, field)
            : getBooleanField(receiver, field);
      case JniType.byte:
        return static
            ? getStaticByteField(receiver, field)
            : getByteField(receiver, field);
      case JniType.char:
        return static
            ? getStaticCharField(receiver, field)
            : getCharField(receiver, field);
      case JniType.short:
        return static
            ? getStaticShortField(receiver, field)
            : getShortField(receiver, field);
      case JniType.int_:
        return static
            ? getStaticIntField(receiver, field)
            : getIntField(receiver, field);
      case JniType.long:
        return static
            ? getStaticLongField(receiver, field)
            : getLongField(receiver, field);
      case JniType.float:
        return static
            ? getStaticFloatField(receiver, field)
            : getFloatField(receiver, field);
      case JniType.double_:
        return static
            ? getStaticDoubleField(receiver, field)
            : getDoubleField(receiver, field);
      case JniType.void_:
        throw JniError('a field cannot have type "void"');
      default:
        if (!JniType.isReference(descriptor)) {
          throw JniError('unknown field descriptor "$descriptor"');
        }
        return static
            ? getStaticObjectField(receiver, field)
            : getObjectField(receiver, field);
    }
  }

  /// Writes a field, coercing [value] according to [descriptor].
  void setFieldByType(
    String descriptor,
    JavaRef receiver,
    Pointer<Void> field,
    Object? value, {
    required bool static,
  }) {
    switch (descriptor) {
      case JniType.boolean:
        final v = _expect<bool>(descriptor, value);
        static
            ? setStaticBooleanField(receiver, field, v)
            : setBooleanField(receiver, field, v);
        return;
      case JniType.byte:
        final v = _expect<int>(descriptor, value);
        static
            ? setStaticByteField(receiver, field, v)
            : setByteField(receiver, field, v);
        return;
      case JniType.char:
        final v = _expect<int>(descriptor, value);
        static
            ? setStaticCharField(receiver, field, v)
            : setCharField(receiver, field, v);
        return;
      case JniType.short:
        final v = _expect<int>(descriptor, value);
        static
            ? setStaticShortField(receiver, field, v)
            : setShortField(receiver, field, v);
        return;
      case JniType.int_:
        final v = _expect<int>(descriptor, value);
        static
            ? setStaticIntField(receiver, field, v)
            : setIntField(receiver, field, v);
        return;
      case JniType.long:
        final v = _expect<int>(descriptor, value);
        static
            ? setStaticLongField(receiver, field, v)
            : setLongField(receiver, field, v);
        return;
      case JniType.float:
        final v = _expectNum(descriptor, value);
        static
            ? setStaticFloatField(receiver, field, v)
            : setFloatField(receiver, field, v);
        return;
      case JniType.double_:
        final v = _expectNum(descriptor, value);
        static
            ? setStaticDoubleField(receiver, field, v)
            : setDoubleField(receiver, field, v);
        return;
      case JniType.void_:
        throw JniError('a field cannot have type "void"');
      default:
        if (!JniType.isReference(descriptor)) {
          throw JniError('unknown field descriptor "$descriptor"');
        }
        if (value != null && value is! JavaRef) {
          throw JniError(
            'expected a JavaRef or null for field "$descriptor", '
            'got ${value.runtimeType}',
          );
        }
        final v = value as JavaRef?;
        static
            ? setStaticObjectField(receiver, field, v)
            : setObjectField(receiver, field, v);
        return;
    }
  }

  static T _expect<T>(String descriptor, Object? value) {
    if (value is T) return value;
    throw JniError(
      'expected a $T for field "$descriptor", '
      'got ${value.runtimeType}',
    );
  }

  static double _expectNum(String descriptor, Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    throw JniError(
      'expected a double for field "$descriptor", '
      'got ${value.runtimeType}',
    );
  }

  // --- Internals -----------------------------------------------------------

  Pointer<Void> _getObject(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetObjectFieldC>>()
        .asFunction<GetObjectFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  bool _getBool(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetBoolFieldC>>()
        .asFunction<GetBoolFieldDart>()(env, receiver, f);
    checkException();
    return result != 0;
  }

  int _getByte(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetByteFieldC>>()
        .asFunction<GetByteFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  int _getChar(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetCharFieldC>>()
        .asFunction<GetCharFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  int _getShort(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetShortFieldC>>()
        .asFunction<GetShortFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  int _getInt(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetIntFieldC>>()
        .asFunction<GetIntFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  int _getLong(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetLongFieldC>>()
        .asFunction<GetLongFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  double _getFloat(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetFloatFieldC>>()
        .asFunction<GetFloatFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  double _getDouble(int slot, Pointer<Void> receiver, Pointer<Void> f) {
    final env = this.env;
    final result = Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<GetDoubleFieldC>>()
        .asFunction<GetDoubleFieldDart>()(env, receiver, f);
    checkException();
    return result;
  }

  void _setObject(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> f,
    Pointer<Void> value,
  ) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetObjectFieldC>>()
        .asFunction<SetObjectFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setBool(int slot, Pointer<Void> receiver, Pointer<Void> f, bool value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetBoolFieldC>>()
        .asFunction<SetBoolFieldDart>()(env, receiver, f, value ? 1 : 0);
    checkException();
  }

  void _setByte(int slot, Pointer<Void> receiver, Pointer<Void> f, int value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetByteFieldC>>()
        .asFunction<SetByteFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setChar(int slot, Pointer<Void> receiver, Pointer<Void> f, int value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetCharFieldC>>()
        .asFunction<SetCharFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setShort(int slot, Pointer<Void> receiver, Pointer<Void> f, int value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetShortFieldC>>()
        .asFunction<SetShortFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setInt(int slot, Pointer<Void> receiver, Pointer<Void> f, int value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetIntFieldC>>()
        .asFunction<SetIntFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setLong(int slot, Pointer<Void> receiver, Pointer<Void> f, int value) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetLongFieldC>>()
        .asFunction<SetLongFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setFloat(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> f,
    double value,
  ) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetFloatFieldC>>()
        .asFunction<SetFloatFieldDart>()(env, receiver, f, value);
    checkException();
  }

  void _setDouble(
    int slot,
    Pointer<Void> receiver,
    Pointer<Void> f,
    double value,
  ) {
    final env = this.env;
    Jvm.fnSlotOf(env, slot)
        .cast<NativeFunction<SetDoubleFieldC>>()
        .asFunction<SetDoubleFieldDart>()(env, receiver, f, value);
    checkException();
  }
}
