#lang racket

;;; edit-tui-rebuild/host/input/scope.rkt —— focus -> command scope
;;;
;;; 当前没有 per-resource command-stack；先按 focus view / panel kind 选 scope：
;;;   editor panel      -> 'editor
;;;   registered view   -> view-scopes 里的 scope（filetree / resources / docs）
;;;   其他              -> 'global
;;;
;;; 每个 scope 的顺序是 local -> global；lookup 在 local 表 unbound 后才落到
;;; global。以后 key-owner（completion）会在前面再叠一层。

(require "../../core/command/api.rkt"
         "../../editor/host-api.rkt"
         "../keymap.rkt")

(provide focus-command-scope
         command-scopes
         host-command-table-for-scope)

(define (focus-command-scope state view-scopes)
  (define vid (editor-focus-view-id state))
  (define pid (editor-focus-panel-id state))
  (or (and vid (hash-ref view-scopes vid #f))
      (and pid (hash-ref view-scopes pid #f))
      (and (eq? (editor-focus-panel-kind state) 'editor) 'editor)
      'global))

(define (command-scopes ed state view-scopes)
  (define focus (focus-command-scope state view-scopes))
  (define owner (active-key-owner ed state))
  (define base
    (if (eq? focus 'global)
        '(global)
        (list focus 'global)))
  (if owner
      (if (memq owner base)
          base
          (cons owner base))
      base))

(define (host-command-table-for-scope scope)
  (case scope
    [(global) global-base-command-table]
    [(editor) editor-base-command-table]
    [(filetree resources docs) navigation-command-table]
    [else command-table-empty]))
