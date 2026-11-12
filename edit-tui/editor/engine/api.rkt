#lang racket

;;; edit-tui/editor/engine/api.rkt —— 兼容聚合面
;;;
;;; 宿主需要全量能力时 require 这里；editor 内部模块应 require 更窄的
;;; read / user-write / ui-write / lifecycle。

(require "read.rkt"
         "user-write.rkt"
         "ui-write.rkt"
         "lifecycle.rkt")

(provide (all-from-out "read.rkt"
                       "user-write.rkt"
                       "ui-write.rkt"
                       "lifecycle.rkt"))
