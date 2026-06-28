---
title: 概览
description: Soma 是什么，以及它背后的心智模型。
---

Soma 是一个 Erlang/OTP 原生的 agent 运行时。核心论点是：一次 agent 运行**不是
在循环里调用工具的函数**——它是一棵受监督的 OTP 进程树。Erlang/OTP 负责执行
语义（超时、取消、监控、崩溃隔离、重启策略）；步骤列表只描述*要做什么*。

## 心智模型

actor 模型加上 OTP 监督：每一个 session、run 和 tool call 都是一个 actor——一个
拥有私有邮箱、只靠消息传递通信的隔离进程。OTP 的监督与 monitor 提供了真正关键的
容错层。

## 下一步

这一页是文档的种子。后续的切片会移植完整文档和架构图。
