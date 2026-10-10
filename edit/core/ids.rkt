#lang racket

;;; edit-rebuild/core/ids.rkt —— 跨层共享的 id 词汇（纯）
;;;
;;; 这些符号原先散落在 config / session / command / feature 各层各写一份字面量。
;;; 集中到这里，改一个名字只改一处。
;;;
;;;   slot-*   框架骨架的命名洞（config 的 layout + session 的 bindings 键）

(provide slot-side slot-editor slot-bottom slot-docs)

(define slot-side 'side)
(define slot-editor 'editor)
(define slot-bottom 'bottom)
;; 文档区：贴在底部区**上方**（状态行仍在最底），横跨编辑区宽。
(define slot-docs 'docs)
