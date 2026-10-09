#lang racket

;;; edit/session.rkt —— 会话实现聚合出口
;;;
;;; 会话内核按功能拆在 session/ 下，这里只聚合 re-export：
;;;   session/value.rkt      会话值 + 构造 + 纯字段变换 + 展示态 + 面板查询（纯）
;;;   session/doc.rkt        文档域状态：did<->path + 保存句柄 + 文档键表（纯）
;;;   session/focus.rkt      焦点 set
;;;   session/core.rkt       ★ 唯一 require core/editor：文档 / 视图 / 几何 / 渲染 / 读 + 内核适配
;;;   session/panel.rkt      状态窗口：枚举 / 互换 / refresh / 渲染前准备
;;;   session/bottom.rkt     底部区（status/input/log 互斥）+ log 通道
;;;   session/prompt.rkt     输入行
;;;   session/structure.rkt  结构手术：显示 / 分屏 / 关闭 / 显隐 / 尺寸 / 浮动窗口
;;;   session/edit.rkt       操作原语：焦点 / 滚动 / 编辑 / 选区 / 剪贴板
;;;   session/mouse.rkt      鼠标
;;;   session/plugin.rkt     document 插件绑定 / 写回
;;;   session/hook.rkt       生命周期通知
;;;   session/render.rkt     统一渲染入口（刷面板 + 应用插件）
;;;
;;; 命令层 / 特性 / 后端 require 本模块即可。

(require "session/value.rkt"
         "session/doc.rkt"
         "session/focus.rkt"
         "session/core.rkt"
         "session/panel.rkt"
         "session/bottom.rkt"
         "session/prompt.rkt"
         "session/structure.rkt"
         "session/edit.rkt"
         "session/mouse.rkt"
         "session/plugin.rkt"
         "session/hook.rkt"
         "session/render.rkt")

(provide (all-from-out "session/value.rkt"
                       "session/doc.rkt"
                       "session/focus.rkt"
                       "session/core.rkt"
                       "session/panel.rkt"
                       "session/bottom.rkt"
                       "session/prompt.rkt"
                       "session/structure.rkt"
                       "session/edit.rkt"
                       "session/mouse.rkt"
                       "session/plugin.rkt"
                       "session/hook.rkt"
                       "session/render.rkt"))
