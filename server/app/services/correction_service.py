"""转写噪音清洗与学科术语校正服务（架构设计 §1.2、T2-03）。

依据 ``transcript-guide.md``（转写文本处理指南）沉淀的实战经验：
1. 幻觉与噪音行过滤（静默段重复、提示词回灌、引擎幻觉行等）。
2. 同音错字与专业术语纠正（工程力学、普通物理、线性代数、电工电子）。
3. 产出规范的勘误表（Errata Table）。
"""

from __future__ import annotations

import re
from typing import Any
from pydantic import BaseModel

from app.providers.base import LLMMessage, LLMOptions, LLMProvider

__all__ = ["CorrectionService", "ErrataResult"]


class ErrataResult(BaseModel):
    """校正结果。"""

    cleaned_text: str
    corrected_text: str
    errata: list[dict[str, Any]]


# Whisper 常见静默幻觉与固定垃圾行正则
HALLUCINATION_PATTERNS = [
    r"请不吝点赞[、，\s]*订阅[、，\s]*转发.*",
    r"(?:课后作业[，,\s]*){3,}",
    r"(?:别吵[，,\s]*){3,}",
    r"(?:在这个时候[，,\s]*){3,}",
    r"打赏支持明镜与点点栏目.*",
    r"（相）关术语.*",
    r"^[\s\-_=]{5,}$",
]

# 核心专业术语同音错字校正字典（原词, 替换词, 适用说明）
# 来源于实战累积 (transcript-guide.md)
BUILTIN_TERM_MAPPINGS: list[tuple[str, str, str]] = [
    ("耳朵", "力偶", "工程力学：力偶被误识别为耳朵"),
    ("力有", "力偶", "工程力学"),
    ("迷友", "力偶", "工程力学"),
    ("利息的分析", "力系的分析", "工程力学：力系误写为利息"),
    ("利息", "力系", "工程力学"),
    ("主持", "主矢", "工程力学"),
    ("主具", "主矩", "工程力学"),
    ("主据", "主矩", "工程力学"),
    ("2D感键", "二力杆件", "工程力学"),
    ("二力构件", "二力杆件", "工程力学"),
    ("脚帘", "铰链", "工程力学"),
    ("固定当地约束", "固定端约束", "工程力学"),
    ("女子式", "余子式", "线性代数"),
    ("男子式", "代数余子式", "线性代数"),
    ("代语", "代数余子式", "线性代数"),
    ("注證", "伴随矩阵", "线性代数"),
    ("右翼举针", "可逆矩阵", "线性代数"),
    ("右翼", "可逆", "线性代数"),
    ("万岁举证", "逆矩阵", "线性代数"),
    ("万岁", "奇异矩阵", "线性代数"),
    ("初到旁变化", "初等行变换", "线性代数"),
    ("出的旁变换", "初等行变换", "线性代数"),
    ("出了旁变换法", "初等行变换法", "线性代数"),
    ("出等变换", "初等变换", "线性代数"),
    ("对象症", "对角阵", "线性代数"),
    ("充量", "动量", "普通物理1：动量误识别为充量"),
    ("国外力", "合外力", "普通物理1"),
    ("原位移", "元位移", "普通物理1"),
    ("原宫", "元功", "普通物理1"),
    ("截尔弘夫", "基尔霍夫", "电工电子"),
    ("鞋尔波斯", "基尔霍夫", "电工电子"),
    ("变连", "并联", "电工电子"),
    ("边连", "并联", "电工电子"),
    ("穿连", "串联", "电工电子"),
    ("带油制度", "待求支路", "电工电子"),
    ("带球之路", "待求支路", "电工电子"),
    ("制度", "支路", "电工电子"),
    ("置入", "支路", "电工电子"),
    ("红绿园", "恒流源", "电工电子"),
    ("迪亚的语词", "叠加定理", "电工电子"),
    ("迪亚定理", "叠加定理", "电工电子"),
]


class CorrectionService:
    """转写文本校正服务。"""

    def __init__(self, llm_provider: LLMProvider | None = None) -> None:
        self.llm = llm_provider

    def filter_hallucinations(self, text: str) -> str:
        """清洗 Whisper 引擎幻觉噪音与重复行。"""
        lines = text.splitlines()
        cleaned_lines = []
        last_line = ""
        repeat_count = 0

        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue

            # 匹配已知幻觉模式
            is_hallucination = False
            for pattern in HALLUCINATION_PATTERNS:
                if re.search(pattern, stripped):
                    is_hallucination = True
                    break
            if is_hallucination:
                continue

            # 过滤相邻连续重复句子（Whisper 常见卡死重复）
            if stripped == last_line:
                repeat_count += 1
                if repeat_count >= 2:
                    continue
            else:
                repeat_count = 0
                last_line = stripped

            cleaned_lines.append(line)

        return "\n".join(cleaned_lines)

    def apply_term_corrections(
        self, text: str
    ) -> tuple[str, list[dict[str, Any]]]:
        """应用内建学科术语错词校正，生成勘误表。"""
        corrected = text
        errata: list[dict[str, Any]] = []

        for orig, target, note in BUILTIN_TERM_MAPPINGS:
            if orig in corrected:
                # 寻找首次出现的上下文（前后 15 字）
                idx = corrected.find(orig)
                start = max(0, idx - 15)
                end = min(len(corrected), idx + len(orig) + 15)
                context = corrected[start:end].replace("\n", " ")

                # 替换
                corrected = corrected.replace(orig, target)

                errata.append(
                    {
                        "original": orig,
                        "corrected": target,
                        "context": context,
                        "note": note,
                    }
                )

        return corrected, errata

    async def correct_transcript(self, raw_text: str) -> ErrataResult:
        """完整清洗与校正流程。"""
        cleaned = self.filter_hallucinations(raw_text)
        corrected, errata = self.apply_term_corrections(cleaned)

        # 若配有 LLM 且文本有内容，可进行自适应勘误增强（留作 M3 扩展点）
        return ErrataResult(
            cleaned_text=cleaned,
            corrected_text=corrected,
            errata=errata,
        )
