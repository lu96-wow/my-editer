#lang racket

;;; edit-tui/plugins/bilingual/action.rkt —— 双语插件的纯 action
;;;
;;; action 只描述宿主还需要做什么；host 解释，插件不直接做 IO /
;;; 生命周期 / layout。

(provide (struct-out bilingual-open-action)
         (struct-out bilingual-close-action)
         (struct-out bilingual-focus-action)
         (struct-out bilingual-replace-source-action))

(struct bilingual-open-action
  (source-doc-id translator-id) #:transparent)

(struct bilingual-close-action
  (source-doc-id) #:transparent)

(struct bilingual-focus-action
  (mirror-view-id) #:transparent)

;; lines : (listof string)，替换 [start-line, end-line)
(struct bilingual-replace-source-action
  (source-doc-id start-line end-line lines) #:transparent)
