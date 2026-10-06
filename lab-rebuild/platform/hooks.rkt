#lang racket

(require "state.rkt")

;;; lab-rebuild/platform/hooks.rkt —— 具名钩子点（平台扩展点）
;;;
;;; 钩子存储仍在 app（per-app，测试互不串），本模块把「有哪些钩子点、参数是什么」
;;; 集中声明，并提供 (app . args) 形式的调用约定：handler 第一参数永远是 app。
;;;
;;;   hook-run!       顺序跑完，忽略返回值（通知型）
;;;   hook-run-first! 顺序跑，返回第一个非 #f（拦截型：「第一个插手的赢」）
;;;
;;; 钩子点与参数：
;;;   post-command        (app)                      每个事件派发后
;;;   before-render       (app)                      每帧渲染前（插件同步 / 写回属性）
;;;   after-edit          (app vid changes)          任何文本变更后（属性插件用）
;;;   after-insert        (app vid changes)          用户打字 / 退格 / 粘贴后（补全 refine 用）
;;;   after-nav           (app)                      光标移动后（弹层取消用）
;;;   before-insert       (app text) -> #f | '() | changes
;;;                       #f = 不插手；'() = 插手但不改文本；changes = 已改文本
;;;   before-backspace    (app) -> #f | '() | changes
;;;   document-opened     (app did)                  文档加入 editor 后
;;;   document-closed     (app did)                  文档关闭、清理前
;;;   focus-changed       (app vid)                  焦点变化后
;;;   mode-changed        (app old new)              模态变化后（Phase 3 接）
;;;   job-tick            (app)                      异步结果可能到达（后端唤醒 / 每事件）

(provide hook-points
         hook-add! hook-remove! hook-run! hook-run-first!)

(define hook-points
  '(post-command
    before-render
    after-edit
    after-insert
    after-nav
    before-insert
    before-backspace
    document-opened
    document-closed
    focus-changed
    mode-changed
    job-tick))

(define (hook-add! a name proc) (app-hook-add! a name proc))
(define (hook-remove! a name proc) (app-hook-remove! a name proc))
(define (hook-run! a name . args) (apply app-notify! a name args))
(define (hook-run-first! a name . args) (apply app-hook-first! a name args))
