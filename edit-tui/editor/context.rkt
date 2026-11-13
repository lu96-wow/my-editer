#lang racket

(require "plugin.rkt"
         "contributions.rkt")

;;; edit-tui/editor/context.rkt —— editor 实例
;;;
;;; editor = 可变 engine + 不可变 hook registry + 插件列表。
;;; State 不放在这里：State 是纯值，由 host 在每帧传入操作面。
;;;
;;; command-table-cache 是 editor 实例内部的派生缓存：contributions registry
;;; 在 editor 生命周期内不可变，同一 scope 的 command-table 只建一次。
;;;
;;; workspace 是 host 维护的语言分析快照（纯值）。它不进 State，也不属于
;;; engine；插件只读，同步由 host/workspace.rkt 负责。
;;;
;;; sources 是 host 维护的来源权威索引（buffer > disk）。它同样不进 State，
;;; 也不暴露给插件；host/source.rkt 负责同步。

(provide (struct-out editor)
         make-editor
         editor-engine
         editor-registry
         editor-contributions
         editor-plugins)

(struct editor
  (engine
   registry
   contributions
   plugins
   timer-service
   command-table-cache   ; scope -> command-table（内部缓存，不进入 State）
   workspace             ; 语言分析快照（纯值，host 同步）
   sources)              ; source-store：buffer / disk 权威索引（host 同步）
  #:mutable
  #:transparent)

(define (make-editor #:engine engine
                     #:registry registry
                     #:plugins [plugins '()]
                     #:contributions [contributions
                                     (make-contribution-registry
                                      (plugins->contributions plugins))]
                     #:timer-service [timer-service #f]
                     #:workspace [workspace #f]
                     #:sources [sources #f])
  (editor engine registry contributions plugins timer-service
          (make-hash) workspace sources))
