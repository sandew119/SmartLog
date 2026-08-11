"""Converts the wood-defect ResNet50 to TFLite, and checks the result.

Run this in Google Colab, or any environment with Python <= 3.13 and
TensorFlow installed. It cannot run in this repo's own toolchain: the local
Python is 3.14, which TensorFlow does not yet support.

    pip install tensorflow

The conversion itself is three lines. Everything else here is verification,
which is the part that matters: a converted model that silently disagrees
with the original is worse than no model, because it fails quietly and only
on the inputs nobody tested.

Usage
-----
    python convert_defect_model.py Wood_Defect_ResNet50_Final.keras

Then copy the two files it writes into the app:

    assets/models/wood_defect.tflite
    assets/models/wood_defect_labels.txt
"""

import json
import os
import sys

import numpy as np
import tensorflow as tf

# The order the model was trained with. Keras stores the *number* of classes
# in the file but never their names, so this is the one thing that has to be
# carried across by hand.
#
# In the training notebook this is `train_ds.class_names` (image_dataset_
# from_directory) or `train_gen.class_indices` (ImageDataGenerator). Both
# sort the class folders alphabetically, so unless the notebook says
# otherwise the alphabetical order of the dataset folders is the answer.
#
# Getting this wrong does not cause an error. It causes the app to call rot
# a knot, confidently, for ever.
#
# The four classes are crack, hole, knot and clear. The order below is
# ALPHABETICAL, which is what both `image_dataset_from_directory` and
# `ImageDataGenerator` produce from folder names. Confirm it against the
# notebook before converting -- if `class_names` prints something else, put
# that here instead.
CLASS_NAMES = [
    "clear",
    "crack",
    "hole",
    "knot",
]


def load(path):
    print("Loading %s ..." % path)
    model = tf.keras.models.load_model(path, compile=False)

    shape = model.input_shape
    classes = model.output_shape[-1]

    print("  input shape :", shape)
    print("  output units:", classes)

    if classes != len(CLASS_NAMES):
        raise SystemExit(
            "The model has %d outputs but CLASS_NAMES lists %d. Fix the list "
            "at the top of this file before converting." % (classes, len(CLASS_NAMES))
        )

    return model


def convert(model, float16=True):
    """float16 by default: about half the size, for no accuracy worth measuring.

    Full float32 would be roughly 100 MB of app download for a ResNet50.
    int8 would be a quarter of that again, but it needs a representative
    calibration dataset, and quantising a model whose job is to tell rot from
    a shadow deserves more care than a default setting.
    """
    converter = tf.lite.TFLiteConverter.from_keras_model(model)

    if float16:
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        converter.target_spec.supported_types = [tf.float16]

    return converter.convert()


def verify(model, tflite_bytes, trials=12, tolerance=2e-2):
    """Runs the same inputs through both and compares.

    Checks the predicted class first -- a disagreement there is a real bug --
    and then the probabilities, which float16 is allowed to move slightly.
    """
    interpreter = tf.lite.Interpreter(model_content=tflite_bytes)
    interpreter.allocate_tensors()

    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]

    print("\n  tflite input :", inp["shape"], inp["dtype"].__name__)
    print("  tflite output:", out["shape"], out["dtype"].__name__)

    rng = np.random.default_rng(0)

    worst = 0.0
    disagreements = 0

    for _ in range(trials):
        # Raw 0-255 pixels, because the preprocessing (RGB->BGR and the
        # ImageNet mean subtraction) is baked into the model's own graph.
        # This is exactly what the Dart side will feed it.
        x = rng.uniform(0, 255, size=(1, 224, 224, 3)).astype(np.float32)

        keras_out = model.predict(x, verbose=0)[0]

        interpreter.set_tensor(inp["index"], x)
        interpreter.invoke()
        lite_out = interpreter.get_tensor(out["index"])[0]

        worst = max(worst, float(np.max(np.abs(keras_out - lite_out))))

        if int(np.argmax(keras_out)) != int(np.argmax(lite_out)):
            disagreements += 1

    print("\n  largest probability difference: %.5f" % worst)
    print("  predicted-class disagreements : %d of %d" % (disagreements, trials))

    if disagreements:
        raise SystemExit(
            "The converted model predicts a different class from the "
            "original. Do not ship this."
        )

    if worst > tolerance:
        raise SystemExit(
            "Probabilities drifted by %.4f, above the %.4f tolerance. Try "
            "converting without float16." % (worst, tolerance)
        )

    print("  OK - the converted model agrees with the original.")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    src = sys.argv[1]
    out_dir = os.path.dirname(os.path.abspath(src))

    model = load(src)

    print("\nConverting to TFLite (float16) ...")
    blob = convert(model)

    tflite_path = os.path.join(out_dir, "wood_defect.tflite")
    with open(tflite_path, "wb") as f:
        f.write(blob)

    labels_path = os.path.join(out_dir, "wood_defect_labels.txt")
    with open(labels_path, "w", encoding="utf-8") as f:
        f.write("\n".join(CLASS_NAMES) + "\n")

    verify(model, blob)

    print("\nWrote:")
    print("  %s  (%.1f MB)" % (tflite_path, len(blob) / 1e6))
    print("  %s" % labels_path)
    print("\nCopy both into the app under assets/models/.")

    # Handy for pasting into the Dart side.
    print("\nLabels, in order:")
    print(json.dumps(CLASS_NAMES, indent=2))


if __name__ == "__main__":
    main()
