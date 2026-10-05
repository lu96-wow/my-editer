#lang racket

(require "../../core/editor.rkt"
         "state.rkt"
         "paths.rkt"
         "../plugin/manager.rkt")

;;; lab/app/plugins.rkt —— app 与插件层的接缝
;;;
;;; app 只做两件事：
;;;   1) 告诉 manager「哪些文档算真实文件」（有路径的），其余（*tree*/*state* 等）不跑插件；
;;;   2) 每 tick 调 manager：sync! 派活、poll! 收结果写回。
;;;
;;; 插件层本身不认识 app / 路径 / 终端 —— 那些策略都在这里。

(provide app-plugin-doc-infos app-plugin-tick!
         app-plugin-note-change!
         app-plugin-source app-plugin-forget!)

;; 真实文件（有路径）的 (did path) 列表；内部面板文档不参与。
(define (app-plugin-doc-infos a)
  (for/list ([did (in-list (editor-document-id-list (app-ed a)))]
             #:when (path-table-path (app-paths a) did))
    (list did (path-table-path (app-paths a) did))))

;; 一次 tick：为新版本派活 + 收结果应用。返回本次更新的 did 列表。
(define (app-plugin-tick! a)
  (define m (app-plugins a))
  (manager-sync! m (app-ed a) (app-plugin-doc-infos a))
  (manager-poll! m (app-ed a)))

;; 编辑命令把 core 的 change 转成插件层的 diff：
;; change = {before, after}（只有结构）；插入文本要从**新文档**的 after 区间读
;; （editor-view-change-text），我们只把 (l0 c0 l1 c1 inserted) 发给 runner。
(define (app-plugin-note-change! a vid changes)
  (when (pair? changes)
    (define ed (app-ed a))
    (define did (editor-view-document-id ed vid))
    (when (path-table-path (app-paths a) did)
      (define edits
        (for/list ([ch (in-list changes)])
          (define b (change-before ch))
          (define s (range-start b))
          (define e (range-end b))
          (list (point-line s) (point-column s)
                (point-line e) (point-column e)
                (editor-view-change-text ed vid ch))))
      (manager-note-change! (app-plugins a) did edits))))

;; 后端 on-source 用：结果到达就绪的事件源（#f = 同步 runner，无异步源）。
(define (app-plugin-source a) (manager-source (app-plugins a)))

;; 关文档时清掉插件层的状态。
(define (app-plugin-forget! a did) (manager-forget! (app-plugins a) did))
