Rails.application.routes.draw do
  #devise_for :users
  scope format: false do
    resources :projects do
      resources :certificates, :except => [:destroy]
    end
    resources :users
    resources :environments
  end

  root 'root#index'
end
