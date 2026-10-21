#lang racket

;;; edit-tui/lang/racket/api.rkt —— Racket 语言能力的唯一对外面
;;;
;;; 目录约定：
;;;   lang/racket/    Racket 专属实现（词法 / 关键字 / 源码扫描 / 文档 / 补全）
;;;   lang/<other>/   以后新增语言时照这个形状放自己的实现
;;;
;;; 编辑器侧只 require 本文件；不要把 Racket 细节散到 app / boot / plugin。
;;; 四个基础能力：
;;;   highlight    语法高亮（关键字 / 字符串 / 注释 / 数字）
;;;   word-color   同词着色
;;;   docs         标识符文档 / 本地定义
;;;   completion   补全候选 / require 模块路径
;;;
;;; 本模块不 require app / boot / core，保持纯语言层。

(require "racket.rkt"
         "lex.rkt"
         "keywords.rkt"
         "highlight.rkt"
         "word-color.rkt"
         "source.rkt"
         "analysis.rkt"
         "workspace.rkt"
         "pool.rkt"
         "module-index.rkt"
         "local-docs.rkt"
         "docs.rkt"
         "completion.rkt")

(provide (all-from-out "racket.rkt"
                       "lex.rkt"
                       "keywords.rkt"
                       "highlight.rkt"
                       "word-color.rkt"
                       "source.rkt"
                       "analysis.rkt"
                       "workspace.rkt"
                       "pool.rkt"
                       "module-index.rkt"
                       "local-docs.rkt"
                       "docs.rkt"
                       "completion.rkt"))
