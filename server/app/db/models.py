"""ORM 模型 —— **服务端**核心实体（架构设计 §3.1 / PRD §7）。

实体划分（v3.0）：
    - **服务端 18 实体**：原 16 + ``NoteRevision``（冲突 keep-both 版本留档）+ ``SyncState``（三方同步状态）。
    - **客户端 1 实体**：``LocalNoteIndex``（Android sqflite + FTS5，存笔记正文）——
      **属 Flutter 端（M5），服务端不建表**（其「已同步到某台设备」的职责由服务端 ``SyncState`` 承担）。

约定（架构设计 §7.1）：
    - 表名 ``snake_case`` 复数；字段 ``snake_case``；时间戳统一 ``_at`` 后缀（UTC）。
    - 枚举以字符串列落库，避免方言差异（SQLite/Postgres）。
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy import JSON
from sqlalchemy import UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.ids import new_id
from app.db.base import Base


class AsrJob(Base):
    """Durable upload receipt + per-generation ASR state; existing tables unchanged."""
    __tablename__ = "asr_jobs"
    __table_args__ = (UniqueConstraint("recording_id", "source_sha256"),)
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    recording_id: Mapped[str] = mapped_column(ForeignKey("recordings.id"), index=True)
    source_sha256: Mapped[str] = mapped_column(String(64))
    source_path: Mapped[str] = mapped_column(Text)
    source_mtime: Mapped[float] = mapped_column(Float)
    source_size: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24), default="queued", index=True)
    error: Mapped[str] = mapped_column(Text, default="")
    run_generation: Mapped[int] = mapped_column(Integer, default=0)
    result: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.now)
    started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

__all__ = [
    "Course",
    "ScheduleEntry",
    "Recording",
    "Transcript",
    "Note",
    "NoteRevision",
    "SyncState",
    "Courseware",
    "TextbookPage",
    "TextbookIndexEntry",
    "Question",
    "SolutionRecord",
    "SearchIndex",
    "UsageRecord",
    "HandoffPackage",
    "Decision",
    "ProviderConfigRow",
    "AuthToken",
    "ALL_MODELS",
]


def _id_column(prefix: str) -> Mapped[str]:
    """统一主键列（带语义前缀的字符串 ID）。"""
    return mapped_column(String(48), primary_key=True, default=lambda: new_id(prefix))


class Course(Base):
    """课程（工程力学 / 普通物理1 / 线性代数 / 电工电子）。"""

    __tablename__ = "courses"

    id: Mapped[str] = _id_column("course")
    name: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    semester: Mapped[str | None] = mapped_column(String(64))
    teacher: Mapped[str | None] = mapped_column(String(128))
    textbook_ref: Mapped[str | None] = mapped_column(String(256))
    # 课程级「自动录音」开关（FR-33 / 架构设计 v3.3 §3.9.1）：默认关闭，
    # 开启后该课所有时段到点自动录音；由安卓端 AlarmManager 到点实时读取。
    auto_record: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    schedule_entries: Mapped[list["ScheduleEntry"]] = relationship(back_populates="course")
    recordings: Mapped[list["Recording"]] = relationship(back_populates="course")


class ScheduleEntry(Base):
    """课表条目。OCR/导入条目 ``confirmed=false``（待确认）。"""

    __tablename__ = "schedule_entries"

    id: Mapped[str] = _id_column("sch")
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    weekday: Mapped[int] = mapped_column(Integer, nullable=False)  # 1-7
    period: Mapped[int] = mapped_column(Integer, nullable=False)
    start_time: Mapped[str | None] = mapped_column(String(8))  # "HH:MM"
    end_time: Mapped[str | None] = mapped_column(String(8))
    location: Mapped[str | None] = mapped_column(String(128))
    # 周次集合（list[int]，升序去重）——表达单/双周与停课断档（v3.3 §3.9.1）。
    # 破坏性变更：原为 ``String(64)`` 的区间串，现改为整数集合，兼容转换见 core.ids.parse_weeks。
    weeks: Mapped[list[int]] = mapped_column(JSON, default=list)
    # 周次位图（派生列）：由 weeks 通过 core.ids.weeks_to_bitmap 计算，禁止手改；
    # 统一在 schedule_service 单一出口回填，查询用位运算（bitmap & (1 << (week-1))）。
    weeks_bitmap: Mapped[int] = mapped_column(Integer, default=0, nullable=False, index=True)
    source: Mapped[str] = mapped_column(String(16), default="manual")  # manual/ocr/import
    confirmed: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    course: Mapped["Course"] = relationship(back_populates="schedule_entries")
    recordings: Mapped[list["Recording"]] = relationship(back_populates="schedule_entry")


class Recording(Base):
    """录音。音频在校验成功后删除：``file_path`` 置空并记 ``deleted_at``（FR-15）。"""

    __tablename__ = "recordings"

    id: Mapped[str] = _id_column("rec")
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    schedule_entry_id: Mapped[str | None] = mapped_column(
        ForeignKey("schedule_entries.id"), nullable=True
    )
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    duration_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    file_path: Mapped[str | None] = mapped_column(String(512))
    size_bytes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    codec: Mapped[str] = mapped_column(String(8), default="aac")  # wav / aac
    upload_status: Mapped[str] = mapped_column(String(16), default="pending")  # pending/uploaded
    transcription_status: Mapped[str] = mapped_column(
        String(16), default="pending"
    )  # pending/running/success/failed
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    course: Mapped["Course"] = relationship(back_populates="recordings")
    schedule_entry: Mapped["ScheduleEntry | None"] = relationship(back_populates="recordings")
    transcript: Mapped["Transcript | None"] = relationship(back_populates="recording")


class Transcript(Base):
    """转写文本（含术语校正后文本与勘误表）。"""

    __tablename__ = "transcripts"

    id: Mapped[str] = _id_column("trs")
    recording_id: Mapped[str] = mapped_column(
        ForeignKey("recordings.id"), nullable=False, unique=True, index=True
    )
    provider: Mapped[str] = mapped_column(String(24), default="local_gpu")
    raw_text: Mapped[str] = mapped_column(Text, default="")
    corrected_text: Mapped[str | None] = mapped_column(Text)
    errata: Mapped[list[Any]] = mapped_column(JSON, default=list)
    language: Mapped[str] = mapped_column(String(8), default="zh")
    duration_sec: Mapped[float] = mapped_column(Float, default=0.0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    recording: Mapped["Recording"] = relationship(back_populates="transcript")
    note: Mapped["Note | None"] = relationship(back_populates="transcript")


class Note(Base):
    """笔记元数据（v3.0：正文**三处并存**，服务端只存元数据 + ``storage_key``，FR-13/FR-31）。

    同步字段：``note_id``（uuid 稳定逻辑身份）/ ``content_hash``（sha256）/ ``updated_at`` /
    ``origin`` / ``deleted`` / ``local_available`` / ``synced_from``。
    正文本身存于存储（本地 Obsidian 目录 / 对象存储）；Android 端由**客户端** ``LocalNoteIndex``
    （sqflite，M5）承载正文，**服务端不建该表**。
    """

    __tablename__ = "notes"

    id: Mapped[str] = _id_column("note")
    note_id: Mapped[str] = mapped_column(
        String(48), unique=True, index=True, default=lambda: uuid.uuid4().hex
    )  # 稳定逻辑身份（uuid），跨端一致
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    transcript_id: Mapped[str | None] = mapped_column(
        ForeignKey("transcripts.id"), nullable=True, index=True
    )
    lesson: Mapped[int | None] = mapped_column(Integer)  # 第 N 次课
    topic: Mapped[str] = mapped_column(String(128), default="")
    fmt: Mapped[str] = mapped_column(
        "format", String(64), default="融合式（课堂实录 + 拓展讲解）"
    )
    # 仅本地/权威侧有值（云端模式为空，逻辑键走 storage_key）
    obsidian_path: Mapped[str | None] = mapped_column(String(512), unique=True, nullable=True)
    storage_key: Mapped[str | None] = mapped_column(String(512))  # 对象存储 key / 本地相对键
    content_hash: Mapped[str | None] = mapped_column(String(72))  # sha256(markdown 正文字节)
    origin: Mapped[str] = mapped_column(String(16), default="win")  # win / cloud / android
    synced_from: Mapped[str | None] = mapped_column(String(16))  # 上次变更端
    deleted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)  # 软删除 tombstone
    local_available: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)  # 已下发手机
    mindmap: Mapped[str | None] = mapped_column(Text)
    todos: Mapped[list[Any]] = mapped_column(JSON, default=list)
    pending: Mapped[list[Any]] = mapped_column(JSON, default=list)
    marker_stats: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)  # ◉课件/◉教材 计数
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    transcript: Mapped["Transcript | None"] = relationship(back_populates="note")
    revisions: Mapped[list["NoteRevision"]] = relationship(back_populates="note")
    sync_state: Mapped["SyncState | None"] = relationship(back_populates="note")


class NoteRevision(Base):
    """笔记版本留档（冲突 keep-both 的留档表，FR-31）。

    每次同步冲突时保存冲突副本引用（规范版与冲突副本都留档），
    支撑「保留两份、绝不静默覆盖」。
    """

    __tablename__ = "note_revisions"

    id: Mapped[str] = _id_column("nrev")
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id"), nullable=False, index=True
    )
    rev: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    content_hash: Mapped[str] = mapped_column(String(72), nullable=False)
    storage_key: Mapped[str | None] = mapped_column(String(512))
    origin: Mapped[str] = mapped_column(String(16), default="win")  # win / cloud / android
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    note: Mapped["Note"] = relationship(back_populates="revisions")


class SyncState(Base):
    """三方同步状态与冲突标记（FR-31）。

    记录每篇笔记在每端最后一次确认同步的 version/hash（``win_*`` / ``cloud_*`` / ``android_*``），
    同步判定「谁新」一律用 hash 比对；``conflict`` + ``conflict_refs`` 标记待用户裁决的冲突。
    """

    __tablename__ = "sync_states"

    id: Mapped[str] = _id_column("sync")
    note_id: Mapped[str] = mapped_column(
        ForeignKey("notes.note_id"), nullable=False, unique=True, index=True
    )
    win_version: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    win_hash: Mapped[str | None] = mapped_column(String(72))
    cloud_version: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    cloud_hash: Mapped[str | None] = mapped_column(String(72))
    android_version: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    android_hash: Mapped[str | None] = mapped_column(String(72))
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    conflict: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    conflict_refs: Mapped[list[Any]] = mapped_column(JSON, default=list)  # [规范版本hash, 副本hash]
    deleted_tombstone: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    note: Mapped["Note"] = relationship(back_populates="sync_state")


class Courseware(Base):
    """课件（PPTX/PDF）；扫描版走视觉读取。"""

    __tablename__ = "coursewares"

    id: Mapped[str] = _id_column("cw")
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    lesson: Mapped[int | None] = mapped_column(Integer)
    file_path: Mapped[str] = mapped_column(String(512), nullable=False)
    type: Mapped[str] = mapped_column(String(8), default="pptx")  # pptx / pdf
    is_scanned: Mapped[bool] = mapped_column(Boolean, default=False)
    parse_mode: Mapped[str | None] = mapped_column(String(16))  # text / vision
    parse_status: Mapped[str] = mapped_column(String(16), default="pending")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class TextbookPage(Base):
    """教材页（渲染图 + 视觉读取文本 + 是否已回填）。"""

    __tablename__ = "textbook_pages"

    id: Mapped[str] = _id_column("tbp")
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    book_name: Mapped[str] = mapped_column(String(256), nullable=False)
    printed_page: Mapped[int] = mapped_column(Integer, nullable=False)
    render_path: Mapped[str | None] = mapped_column(String(512))
    vision_text: Mapped[str | None] = mapped_column(Text)
    backfilled: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class TextbookIndexEntry(Base):
    """教材例题索引（从导览解析；``in_scope`` 为 ★ 老师已讲到的范围）。"""

    __tablename__ = "textbook_index_entries"

    id: Mapped[str] = _id_column("tbi")
    course_id: Mapped[str] = mapped_column(ForeignKey("courses.id"), nullable=False, index=True)
    example_no: Mapped[str] = mapped_column(String(32), nullable=False)  # 如 "例 1.28"
    summary: Mapped[str | None] = mapped_column(Text)
    printed_page: Mapped[int | None] = mapped_column(Integer)
    knowledge_point: Mapped[str | None] = mapped_column(String(256), index=True)
    in_scope: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Question(Base):
    """题目（拍照/上传 + OCR 题干 + 超纲判定）。"""

    __tablename__ = "questions"

    id: Mapped[str] = _id_column("q")
    source: Mapped[str] = mapped_column(String(16), default="photo")  # photo / upload
    course: Mapped[str | None] = mapped_column(String(128), index=True)
    stem_ocr: Mapped[str] = mapped_column(Text, default="")
    knowledge_point: Mapped[str | None] = mapped_column(String(256), index=True)
    out_of_scope: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    solutions: Mapped[list["SolutionRecord"]] = relationship(back_populates="question")


class SolutionRecord(Base):
    """解答记录（三方交叉；**禁止并列两种结论**）。"""

    __tablename__ = "solution_records"

    id: Mapped[str] = _id_column("sol")
    question_id: Mapped[str] = mapped_column(ForeignKey("questions.id"), nullable=False, index=True)
    teacher_route: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    ai_independent: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    compare_result: Mapped[str] = mapped_column(String(16), default="unknown")  # 一致/冲突
    conflict_reason: Mapped[str | None] = mapped_column(Text)
    final_conclusion: Mapped[str | None] = mapped_column(Text)
    cited_note_paths: Mapped[list[Any]] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    question: Mapped["Question"] = relationship(back_populates="solutions")


class SearchIndex(Base):
    """检索索引（**不存正文**；含一致性校验状态）。"""

    __tablename__ = "search_index"

    id: Mapped[str] = _id_column("idx")
    target_type: Mapped[str] = mapped_column(String(16), default="note")  # note / transcript
    rel_path: Mapped[str] = mapped_column(String(512), nullable=False, index=True)
    keywords: Mapped[list[Any]] = mapped_column(JSON, default=list)
    tokens: Mapped[str | None] = mapped_column(Text)
    consistency_status: Mapped[str] = mapped_column(String(16), default="unknown")  # ok/stale/missing
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class UsageRecord(Base):
    """云 ASR 用量记录（仅 cloud_api；FR-17）。"""

    __tablename__ = "usage_records"

    id: Mapped[str] = _id_column("use")
    ts: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False, index=True
    )
    provider: Mapped[str] = mapped_column(String(24), default="cloud_api")
    audio_seconds: Mapped[float] = mapped_column(Float, default=0.0)
    request_count: Mapped[int] = mapped_column(Integer, default=0)
    est_cost: Mapped[float] = mapped_column(Float, default=0.0)
    actual_cost: Mapped[float] = mapped_column(Float, default=0.0)


class HandoffPackage(Base):
    """交接包（FR-16）；``conventions`` 由代码固定注入。"""

    __tablename__ = "handoff_packages"

    id: Mapped[str] = _id_column("hof")
    generated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    milestone: Mapped[str] = mapped_column(String(16), default="M0")
    stage: Mapped[str | None] = mapped_column(String(64))
    done: Mapped[list[Any]] = mapped_column(JSON, default=list)
    in_progress: Mapped[list[Any]] = mapped_column(JSON, default=list)
    todo: Mapped[list[Any]] = mapped_column(JSON, default=list)
    blocked: Mapped[list[Any]] = mapped_column(JSON, default=list)
    conventions: Mapped[list[Any]] = mapped_column(JSON, default=list)
    adr_refs: Mapped[list[Any]] = mapped_column(JSON, default=list)
    files: Mapped[list[Any]] = mapped_column(JSON, default=list)


class Decision(Base):
    """决策记录（ADR）；**只增不改**。"""

    __tablename__ = "decisions"

    id: Mapped[str] = _id_column("adr")
    title: Mapped[str] = mapped_column(String(256), nullable=False)
    context: Mapped[str | None] = mapped_column(Text)
    decision: Mapped[str | None] = mapped_column(Text)
    rationale: Mapped[str | None] = mapped_column(Text)
    date: Mapped[str | None] = mapped_column(String(32))
    scope: Mapped[str | None] = mapped_column(String(128))


class ProviderConfigRow(Base):
    """Provider 配置落库（与 YAML 一致的镜像；``credential_ref`` 仅存引用）。"""

    __tablename__ = "provider_configs"

    id: Mapped[str] = _id_column("pcfg")
    deployment_mode: Mapped[str] = mapped_column(String(16), default="local")
    transcription_provider: Mapped[str] = mapped_column(String(24), default="local_gpu")
    llm_provider: Mapped[str] = mapped_column(String(24), default="cloud_llm")
    vision_provider: Mapped[str] = mapped_column(String(24), default="cloud_vision")
    storage_backend: Mapped[str] = mapped_column(String(16), default="local_fs")
    credential_ref: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    auth_token: Mapped[str | None] = mapped_column(String(128))
    force_https: Mapped[bool] = mapped_column(Boolean, default=False)
    sync: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)  # enabled/endpoint/scope/conflict_policy/interval_seconds
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class AuthToken(Base):
    """鉴权凭据（云端 API）。"""

    __tablename__ = "auth_tokens"

    id: Mapped[str] = _id_column("tok")
    token: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    purpose: Mapped[str | None] = mapped_column(String(64))
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class SchedulePreferencesRow(Base):
    __tablename__ = "schedule_preferences"
    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    revision: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    value: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)


ALL_MODELS: tuple[type[Base], ...] = (
    Course,
    ScheduleEntry,
    Recording,
    Transcript,
    Note,
    NoteRevision,
    SyncState,
    Courseware,
    TextbookPage,
    TextbookIndexEntry,
    Question,
    SolutionRecord,
    SearchIndex,
    UsageRecord,
    HandoffPackage,
    Decision,
    ProviderConfigRow,
    SchedulePreferencesRow,
    AuthToken,
)
