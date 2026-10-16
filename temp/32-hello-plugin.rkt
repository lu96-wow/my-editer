#lang racket

;;; 32-hello-plugin.rkt —— 样例插件：**require 即注册 / 生效**
;;;
;;; 本模块顶层做的三件事，就是这个插件被 require 时的全部副作用：
;;;   1. define-doc-kind!  → 注册 document 类型 + 命令表
;;;   2. define-plugin!    → 注册面板贡献 + on-load（载入到当前 layout）
;;; 谁 require 它，谁就"装上了"；没人 require，它就不存在（没有面板 / 类型 / 状态）。

(require "../core/editor.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/api/main.rkt")

;; ── 1. document 类型 + 面板自己的键表（焦点在 *hello* 时生效）──
(define hello-res (make-resources))
(define hello-keys
  (keys
   [(key 'q 'ctrl) (λ (ctx) (quit))]))                ; 面板里也能退
(define-doc-kind! 'hello #:keymaps (list hello-keys))

;; ── 2. 面板贡献 + on-load ──
;; 面板 id 'hello，插到当前 layout 第一个 'editor 左侧；载入时造文档并挂进该 leaf。
(define (hello-load w)
  (define-values (_b v) (open-document! hello-res "*hello*"
                                        "hello from plugin\n(require 即生效)"
                                        #:kind 'hello))
  (world-set-layout w (tree-set-view (world-layout w) 'hello v)))

(define-plugin! 'hello
  #:panel   (panel-spec 'hello 'left 1/3 'panel #f)
  #:on-load hello-load)
