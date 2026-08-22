"""学習時に classes.json を書き出すためのヘルパ.

推論側 (django_prediction_API/prediction/views.py) はクラス名をハードコード
しない。ImageFolder が決めたクラス順を正本として、この json を重みと同じ
場所に置いて運ぶ。

なぜ必要か:
    ImageFolder はフォルダ名をソートしてクラス番号を振る。フォルダを1つ
    増やすと後続のクラス番号が全部ズレる。

        4クラス: カクマダニ(0) タカサゴキララマダニ(1) チマダニ(2) マダニ(3)
        5クラス: カクマダニ(0) タカサゴキララマダニ_吸血(1)
                 タカサゴキララマダニ_未吸血(2) チマダニ(3) マダニ(4)
                                              ^^^ 2→3    ^^^ 3→4

    推論側で番号を手で管理していると、更新を忘れたときにエラーも出さずに
    全種を誤ったラベルで返す。学習側に吐かせれば構造的に防げる。

Colab での使い方 (学習セルの後に実行):

    from export_classes_json import export

    export(
        class_names=class_names,       # full_dataset.classes
        save_dir=SAVE_DIR,
        version="5cls-2026-08",
        weights=SAVE_NAME,
    )
"""

import json
import os

# 吸血状態を表すフォルダ名の接尾辞。学習データのフォルダ名に合わせる。
FEEDING_SUFFIXES = {
    "_吸血": "engorged",
    "_未吸血": "unfed",
}

FEEDING_LABEL = {
    "engorged": "（吸血）",
    "unfed": "（未吸血）",
}


def split_class_name(class_name: str):
    """クラス名を (種名, 吸血状態) に分解する.

    >>> split_class_name("タカサゴキララマダニ_吸血")
    ('タカサゴキララマダニ', 'engorged')
    >>> split_class_name("チマダニ")
    ('チマダニ', None)
    """
    for suffix, status in FEEDING_SUFFIXES.items():
        if class_name.endswith(suffix):
            return class_name[: -len(suffix)], status
    return class_name, None


def build_meta(class_names, version, weights, arch="resnet50d"):
    species = {}
    feeding = {}
    for name in class_names:
        sp, status = split_class_name(name)
        species[name] = sp
        if status:
            feeding[name] = status

    return {
        "version": version,
        "weights": weights,
        "arch": arch,
        "note": "classes は学習時の ImageFolder.classes をそのまま写したもの。手で並べ替えないこと。",
        "classes": list(class_names),
        "species": species,
        "feeding": feeding,
        "feeding_label": FEEDING_LABEL,
    }


def export(class_names, save_dir, version, weights, arch="resnet50d", filename="classes.json"):
    """classes.json を save_dir に書き出して内容を表示する."""
    meta = build_meta(class_names, version=version, weights=weights, arch=arch)

    path = os.path.join(save_dir, filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print(f"wrote {path}")
    print()
    print("=== 目で確認すること ===")
    print(f"クラス数: {len(meta['classes'])}")
    for i, name in enumerate(meta["classes"]):
        sp = meta["species"][name]
        st = meta["feeding"].get(name)
        label = sp + FEEDING_LABEL.get(st, "") if st else sp
        print(f"  [{i}] {name:<28} → 表示: {label}")
    print()
    print("この重みを使うには、classes.json を重みと同じ場所に置いて")
    print("土台イメージを作り直す:")
    print(f"  ./scripts/build-base-image.sh <次のバージョン> --cls-weights {weights}")
    return path


if __name__ == "__main__":
    # 5クラス化したときの出力例 (実行して確認できる)
    example = [
        "カクマダニ",
        "タカサゴキララマダニ_吸血",
        "タカサゴキララマダニ_未吸血",
        "チマダニ",
        "マダニ",
    ]
    meta = build_meta(example, version="5cls-example", weights="resnet50_yolo_crop_5cls.pth")
    print(json.dumps(meta, ensure_ascii=False, indent=2))
