#lang racket

;;; edit-tui/demo/save.rkt —— 共享 status/input 槽 + 保存确认
;;;
;;;   racket edit-tui/demo/save.rkt
;;;
;;; 底部是一个 region，里面有两个真正的 core view（buffer 支撑）：
;;;   *status* : 状态栏
;;;   *input*  : 输入栏 / 保存确认
;;; 同一时刻只显示 active 的那个；prompt 结束会切回 status。
;;;
;;; 编辑文件后 C-q：会进入 y/n/yall/nall 的保存确认。
;;;   y = 保存当前；n = 跳过当前；yall = 保存剩余全部；nall = 跳过剩余全部
;;;   输入答案后按 Enter。
;;; C-x C-k 关闭当前 document 也会走同一套确认。
;;;
;;; 其它键：编辑、C-w arrows split、C-w C-w close view、M-w close panel、
;;; C-x C-f open file、M-方向 focus。

(require "../theme/main.rkt"
         racket/path
         racket/file
         "../base/id.rkt"
         "../model/layout.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/chrome.rkt"
         "../effects/engine.rkt"
         "../chrome/slot.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define doc-path
  (path->string (build-path (find-system-path 'temp-dir)
                            "rebuild-save-demo.txt")))

(define did (doc-id 1))
(define vid (view-id 1))
(define editor-rid (region-id 1))
(define chrome-rid (region-id 2))

(define engine (make-engine))
(void (engine-create-doc! engine did "rebuild-save-demo.txt"
                          "Edit this file, then press C-q.\n\nSave confirmation:\n  y  save current\n  n  skip current\n  !  save all remaining\n  ?  skip all remaining\n\nC-x C-k also asks before closing this document.\n"))
(void (engine-create-view! engine vid did))

;; 打开时保存基线 = 当前版本；之后编辑变 dirty。
(define baseline (engine-view-doc-version (make-engine-view engine) did))

(define ws0 (workspace-empty))
(define ws1 (workspace-add-doc ws0 did
                               (make-doc-meta "rebuild-save-demo.txt"
                                              #:path doc-path
                                              #:saved-version baseline)))
(define ws2 (workspace-add-view ws1 vid (view-meta did (hash))))
(define ws3 (workspace-add-region ws2 editor-rid
                                  (region editor-rid (list (view-member vid)) vid 'editor)))

(define state0
  (make-state #:workspace ws3
              #:ids (make-id-counter 2 2 3 1)))

;; 安装 status/input 两个 buffer view + 共享 region。
(define state1 (install-chrome! engine state0 chrome-rid))
(define layout*
  (make-split 'tb
              (list (make-leaf editor-rid (flex 1))
                    (make-leaf chrome-rid (fixed 1) #:borders '()))
              (flex 1)))
(define ws4 (struct-copy workspace (state-workspace state1) [layout layout*]))
(define state2 (state-set-focus (state-set-workspace state1 ws4) vid))

(module+ main
  (run-app default-env state2 engine))
