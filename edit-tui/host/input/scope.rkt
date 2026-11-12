#lang racket

;;; edit-tui/host/input/scope.rkt —— focus -> command scope
;;;
;;; focus view / panel kind -> command scope：
;;;   editor panel      -> 'editor（resource command-stack 由 dispatch 插入）
;;;   registered view   -> view-scopes 里的 scope（filetree / resources / docs）
;;;   其他              -> 'global
;;;
;;; 每个 scope 的顺序是 local -> global；lookup 在 local 表 unbound 后才落到
;;; global。key-owner（completion）由 dispatch 在前面再叠一层。

(require "../../core/command/api.rkt"
         "../../editor/host-api.rkt"
         "../keymap.rkt")

(provide focus-command-scope
         host-command-table-for-scope)

(define (focus-command-scope state view-scopes)
  (define vid (editor-focus-view-id state))
  (define pid (editor-focus-panel-id state))
  (or (and vid (hash-ref view-scopes vid #f))
      (and pid (hash-ref view-scopes pid #f))
      (and (eq? (editor-focus-panel-kind state) 'editor) 'editor)
      'global))


(define (host-command-table-for-scope scope)
  (case scope
    [(global) global-base-command-table]
    [(editor) editor-base-command-table]
    [(filetree resources docs) navigation-command-table]
    [else command-table-empty]))
