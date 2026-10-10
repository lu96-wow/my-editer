#lang racket

;;; edit-rebuild/core/extension/spec.rkt —— 插件包（能力清单项）
;;;
;;; 局部问题：一个可启用的「能力包」= 名字 + 全局安装 + 它带的 face 插件。
;;; 启用哪些是 config（只给名字）；名字解析成实现由 catalog 做；本模块只定义包值。
;;;
;;; 与 extension/face-plugin.rkt 的分工：
;;;   extension/spec.rkt       插件**包**（装配用）
;;;   extension/face-plugin.rkt face **插件协议**（按文档筛选 / 层 / 增量）

(provide (struct-out plugin-spec) plugin-face-plugins install-plugins)

(struct plugin-spec (name install face-plugins) #:transparent)
;; name        : symbol
;; install     : session -> session          注册 hook / handler / panel 等贡献
;; face-plugins: (listof face-plugin)       随包启用的 face 插件

;; 一组插件包带的全部 face 插件（顺序 = 包顺序 ⊕ 包内顺序）。
(define (plugin-face-plugins specs)
  (append* (for/list ([p (in-list specs)]) (plugin-spec-face-plugins p))))

;; 装一组插件包的全局贡献（hook / handler / panel…）。
(define (install-plugins s specs)
  (for/fold ([s s]) ([p (in-list specs)]) ((plugin-spec-install p) s)))
