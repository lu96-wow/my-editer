#lang racket

;;; ============================================================================
;;; command.rkt —— 命令块：全局键位表 + 分发
;;; ============================================================================
;;;
;;; 「命令」这一块只含**作用于全局**的东西。每个 pane 自己的按键不在这里：
;;; 编辑格在 buffer.rkt，文件树在 tree.rkt。
;;;
;;; 分发顺序：
;;;   1) resize            → 改屏幕尺寸
;;;   2) 退出问答进行中     → 交给 state 的 quit-answer（y/n/Esc）
;;;   3) key 命中 global-keys → 执行全局动作
;;;   4) 否则 dispatch      → 交给焦点 pane 的 input / pointer（state.rkt）
;;;
;;; dispatch 会执行 pane 返回的 effects（开/关文档、加/关视图、聚焦…），
;;; 之后 project! 把所有组件重新投影一次 —— 所以「处理完状态就是对的」，
;;; 不需要在各处手工调用某个组件的投影。

(require "state.rkt"
         "input.rkt")

(provide handle global-keys)

;;; ---------- 全局键位表 ----------

;; Ctrl-, / Ctrl+. 调焦点窗口宽度；Ctrl-Q 退出（先逐个问未保存的编辑器）。
(define global-keys
  (hash (key #\, #t #f #f #f) (lambda (a) (editor-resize-focus a -1))
        (key #\. #t #f #f #f) (lambda (a) (editor-resize-focus a +1))
        (key #\q #t #f #f #f) quit-request))

(define (global-action in) (and (key? in) (hash-ref global-keys in #f)))

;;; ---------- 分发 ----------

(define (handle a in)
  (define a1
    (cond
      [(resize? in) (struct-copy app a [rows (resize-rows in)] [cols (resize-cols in)])]
      [(app-quit-ask a) (quit-answer a in)]                 ; 退出问答优先
      [(global-action in) => (lambda (f) (f a))]
      [else (dispatch a in)]))
  (project! a1))
