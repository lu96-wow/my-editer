#lang racket

;;; edit-tui/features/open-buffers/open-buffers.rkt —— 已打开缓冲区的文本索引
;;;
;;; 供 completion / docs 等“解析本地 require”的路径使用：
;;;   path -> 当前 buffer 文本
;;; 同一路径即使磁盘上有旧版本，也优先使用打开中的内容。

(require "../../editor/api.rkt")

(provide editor-open-texts)

(define (editor-open-texts ed state)
  (for/fold ([h (hash)]) ([r (in-list (resources-list (state-resources state)))])
    (define p (resource-path r))
    (cond
      [(not p) h]
      [else
       (define text (editor-doc-text ed (resource-doc-id r)))
       (cond
         [(not text) h]
         [else (hash-set h (resource-normalize-path p) text)])])))
