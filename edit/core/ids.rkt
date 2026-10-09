#lang racket

;;; edit/core/ids.rkt —— 跨层共享的 id 词汇（纯）
;;;
;;; 这些符号原先散落在 config / session / command / feature 各层各写一份字面量。
;;; 集中到这里，改一个名字只改一处。
;;;
;;;   slot-*   框架骨架的命名洞（config 的 layout + session 的 bindings 键）
;;;   panel-*  面板身份（panel id；也用于按 id 打开 / 找到面板）

(provide
 ;; 框架 slot
 slot-side slot-editor slot-bottom
 ;; 面板 id
 panel-input panel-status panel-log panel-tree panel-buffers)

(define slot-side 'side)
(define slot-editor 'editor)
(define slot-bottom 'bottom)

(define panel-input 'input)
(define panel-status 'status)
(define panel-log 'log)
(define panel-tree 'tree)
(define panel-buffers 'buffers)
