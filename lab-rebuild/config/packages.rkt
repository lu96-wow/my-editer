#lang racket

(require racket/runtime-path)

;;; lab-rebuild/config/packages.rkt —— 要加载的功能包（纯数据 + 路径）
;;;
;;; 每条 = (name module-path init-symbol / #f)。
;;; 模块路径用 define-runtime-path 解析，编译后 / 换 CWD 都找得到。
;;;
;;; 基础编辑包 builtin/edit.rkt 不在这里：app 直接 require（它提供 app-resize! 等
;;; 平台动作）；其余功能包按这张表加载，于是「加载哪些」是配置。

(provide package-catalog)

(define-runtime-path builtin-dir "../builtin")

(define (pkg name file [init #f])
  (list name (build-path builtin-dir file) init))

(define package-catalog
  (list (pkg 'tree      "tree.rkt")                 ; 面板：模块加载即注册 provider
        (pkg 'buffers   "buffers.rkt")
        (pkg 'complete  "complete.rkt"  'complete-init!)
        (pkg 'docs      "docs.rkt"      'docs-init!)
        (pkg 'indent    "indent.rkt")                  ; 加载即覆盖 newline-and-indent
        (pkg 'highlight "highlight.rkt" 'highlight-init!)
        (pkg 'autopair  "autopair.rkt"  'autopair-init!)))
