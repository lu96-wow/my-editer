#lang racket

;;; dispatch/context.rkt —— 命令看到的派生视图（纯值）
;;; layer  : dispatch
;;; effect : 无（纯值）

;;; ctx 由 dispatch 构造，命令拿它做决策、返回 transition。
;;; 命令**不直接**改 core；需要读文本 / 光标时通过 engine（只读查询接口）。
;;;
;;;   env     : environment（只读策略）
;;;   state   : 根 State（纯）
;;;   event   : 触发本次命令的事件
;;;   subject : view-id | region-id | #f   命令作用的稳定主体
;;;   engine  : engine-view | #f           只读查询接口（块 4 定义具体协议）
;;;
;;; subject 的解析在 dispatch：
;;;   · 键盘 -> 当前 focus view；
;;;   · 鼠标 -> 命中区域 / 视图（由 geometry 提供）；
;;;   · 手势 -> gesture owner。
;;; 所以命令不需要知道鼠标坐标或 panel 值。

(provide (struct-out ctx)
         ctx?
         make-ctx)

(require "../env/environment.rkt"
         "../model/state.rkt"
         "../base/event.rkt")

(struct ctx (env state event subject engine) #:transparent)

(define (make-ctx env state event [subject #f] [engine #f])
  (ctx env state event subject engine))
