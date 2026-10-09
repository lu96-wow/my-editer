#lang racket

;;; edit/command/session.rkt —— 会话实现聚合出口
;;;
;;; 实现按功能拆成若干模块，这里只聚合 re-export：
;;;   session-value.rkt   会话值 + 构造 + 展示态 + 面板查询（纯）
;;;   session-doc.rkt     文档域状态：did<->path + 保存句柄 + 文档键表（纯）
;;;   session-focus.rkt   焦点 set
;;;   session-core.rkt    ★ 唯一 require core/editor：文档 / 视图 / 几何 / 渲染 / 读 + 内核适配
;;;   session-panel.rkt   状态窗口机制：枚举 / 互换 / handler 链 / refresh
;;;   session-bottom.rkt  底部区（status/input/log 互斥）+ log 通道
;;;   session-prompt.rkt  输入行
;;;   session-edit.rkt    结构手术 + 操作原语
;;;   session-mouse.rkt   鼠标
;;;
;;; 命令层 / 特性 / 后端 require 本模块即可。

(require "session-value.rkt"
         "session-doc.rkt"
         "session-focus.rkt"
         "session-core.rkt"
         "session-panel.rkt"
         "session-bottom.rkt"
         "session-prompt.rkt"
         "session-edit.rkt"
         "session-mouse.rkt")

(provide (all-from-out "session-value.rkt"
                       "session-doc.rkt"
                       "session-focus.rkt"
                       "session-core.rkt"
                       "session-panel.rkt"
                       "session-bottom.rkt"
                       "session-prompt.rkt"
                       "session-edit.rkt"
                       "session-mouse.rkt"))
