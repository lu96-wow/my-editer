#lang racket

;;; edit-tui-rebuild/filetree/slice.rkt —— app-state.store['filetree'] 的切片存取
;;;
;;; Root State 的 store 是一个 hash：每个面板域把自己的纯状态放在自己的 key 下。
;;; 这个模块只给 filetree 内部（commands / sync）用，不导出到 API。
;;;
;;; 命名：
;;;   (filetree-of state)     读：没有时给 empty-filetree
;;;   (filetree-put state f)  写：返回新 state（纯）

(require "../app/state.rkt"
         "model.rkt")

(provide filetree-of
         filetree-put)

(define (filetree-of state)
  (hash-ref (app-state-store state) 'filetree (empty-filetree)))

(define (filetree-put state f)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]))
