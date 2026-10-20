#lang racket

;;; edit-tui-rebuild/engine/api.rkt —— buffer / view engine 骨架 API
;;;
;;; 纯 State 只存 id；engine 拥有真正的 core buffer / view。
;;; 插件通过这里写 UI view / 查询光标；runtime 解释 action 时写 engine。

(require "action.rkt"
         "model.rkt")

(provide (all-from-out "action.rkt"
                       "model.rkt"))
