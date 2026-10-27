"""Pure source-marker statistics shared by note generation and backfill."""


def count_markers(text: str) -> dict[str, int]:
    """统计来源标记数量，保留原始文本逐字计数的语义。"""
    return {
        "classroom": text.count("◉课堂"),
        "courseware": text.count("◉课件"),
        "textbook": text.count("◉教材"),
    }
