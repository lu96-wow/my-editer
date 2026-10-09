#lang racket

;;; edit/demo.rkt —— 装配：空编辑器区 + 四个状态窗口（输入 / 状态 / 文件树 / 缓冲区）
;;;
;;; 布局在 config/layout.rkt 里组合声明；这里只按 slot 名把内容填进去。
;;; 编辑器区（editor slot）**先留空**：打开第一个文件时由 session-place-view 填上。
;;;   (demo-session)                      ; 默认：文件树在左
;;;   (demo-session #:layout layout-top)  ; 文件树在上

(require "core/layout.rkt" "core/focus.rkt"
         "config/layout.rkt"
         "command/session.rkt" "command/command.rkt" "command/keys.rkt" "command/binding.rkt"
         "document/document.rkt"
         "feature/status.rkt" "feature/buffers.rkt" "feature/tree.rkt" "feature/prompt.rkt")

(provide demo-session)

(define (demo-session [w 80] [h 24] #:layout [layout layout-left])
  (define s0 (session-blank w h (list base-keys document-keys)))

  ;; 状态窗口：输入行 / 状态行 / 文件树 / 缓冲区
  (define-values (s6 input)  (prompt-install s0 w 1))
  (define-values (s7 status) (status-install s6 w 1))
  (define-values (s8 tree)   (tree-install s7 (current-directory) 26 18))
  (define-values (s9 buf)    (buffers-install s8 26 8))

  ;; tree / buffers 共用同一位置，默认显示 tree
  (define s9* (session-set-visible s9 buf #f))

  ;; 内容（按 slot 名填进 config 的骨架）；editor 留空
  (define side   (stack (list (leaf tree) (leaf buf))))
  (define bottom (split 'tb (list (cons 'flex (leaf status)) (cons 1 (leaf input)))))
  (define bnd (hash 'side side 'bottom bottom))

  (define s10 (document-install (session-assemble s9* layout bnd) edit-keys))
  ;; 初始焦点：文件树（编辑器区为空，打开文件后再进）
  (session-set-focus s10 (focus-set (session-focus s10) tree)))

(module+ main
  (require "tui.rkt")
  (run-tui (demo-session)))
