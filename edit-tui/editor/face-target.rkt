#lang racket

;;; edit-tui/editor/face-target.rkt —— 后台属性写入的稳定目标
;;;
;;; face-target 捕获「某个 document 版本 + 它的 buffer」。后台线程只写这个
;;; document 的 face 端口；文本编辑会生成新的 document，旧目标上的写入不会
;;; 污染新版本。写入是整轨一次 swap，读者只会看到旧/新两条完整 face track。
;;;
;;; 这不是通用状态写入口：只给 attribute worker 用。

(require "../../core/editor.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/track.rkt"
         "context.rkt"
         "engine/read.rkt")

(provide (struct-out face-target)
         editor-doc-face-target
         face-target-set-face-lines!)

(struct face-target
  (buffer
   document)   ; 捕获时的 document 版本；face 写入只作用于它
  #:transparent)

(define (editor-doc-face-target ed did)
  (define buffer (engine-doc-buffer (editor-engine ed) did))
  (and buffer
       (face-target buffer (buffer-version buffer))))

;; face-lines : (listof (vectorof (or/c #f symbol? face?)))，与 document 文本行等长。
;; 一次 document-set-face! = 一次 box swap；不做 clear + 多段写。
(define (face-target-set-face-lines! target face-lines)
  (document-set-face! (face-target-document target)
                      (track-of-list face-lines))
  (void))
