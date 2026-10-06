# frozen_string_literal: true

# Contract Desk (drawn from config/routes.rb with `draw :desk`).
namespace :desk do
  root 'home#index'

  resources :uploads, only: %i[new create]
  resources :contracts, only: %i[new create]
  resources :questions, only: %i[index show update]
  resource :settings, only: %i[edit update]

  resources :clients, only: %i[index show new create edit update] do
    member do
      post :confirm
      post :archive
    end
  end

  resources :documents, only: %i[index show] do
    member do
      get :review
      post :approve
      post :decline
      post :retry
      post :archive
      get 'download/:kind', action: :download, as: :download, constraints: { kind: /source|signed|audit/ }
    end
  end
end
