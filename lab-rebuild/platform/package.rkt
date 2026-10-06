#lang racket

;;; lab-rebuild/platform/package.rkt —— 配置驱动的包加载（平台扩展点）
;;;
;;; 不把功能包写死在 app 里 require：装配时按 **package 表**（config/packages.rkt）
;;; 逐个 `dynamic-require`，触发模块顶层注册（命令 / 键表 / mode / overlay / panel /
;;; 插件），再调它的 init 导出。这就是「插件目录 + 启用集」的加载侧。
;;;
;;; package 条目 = (name module-path init-symbol / #f)
;;;   name        : symbol
;;;   module-path : path / string（相对路径由 catalog 用 define-runtime-path 解析）
;;;   init        : 导出名（(app -> void)）；#f = 只加载不初始化
;;;
;;; ⚠ 加载会执行模块顶层代码，可能建 place / 线程 —— 必须在 tui:with-tui 内
;;;   （app-init 已在里面）调 load-package!，不要在模块加载期做。

(provide package? package-name package-module package-init
         load-package! package-init-proc)

(define (package? x) (and (list? x) (= 3 (length x))))
(define (package-name p) (car p))
(define (package-module p) (cadr p))
(define (package-init p) (caddr p))

;; 实例化模块（触发顶层注册）。已加载过是无害的。
(define (load-package! p)
  (dynamic-require (package-module p) #f))

;; 取 init 过程；#f = 无 / 未导出。
(define (package-init-proc p)
  (define name (package-init p))
  (and name (dynamic-require (package-module p) name)))
