"""课堂学习助手后端应用包。

包结构（见架构设计 §2.1）：
    - config.py          配置系统（本地/云端唯一入口）
    - deps.py            依赖注入（唯一装配处）
    - logging_setup.py   结构化日志
    - errors.py          统一错误码 + 异常处理器
    - api/               接口层（FastAPI 路由）
    - core/              鉴权 / 任务队列 / ID 工具
    - db/                ORM 模型、会话、仓储
    - providers/         四类 Provider 抽象 + 工厂 + 实现
    - services/          业务服务
    - pipelines/         多阶段编排
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
